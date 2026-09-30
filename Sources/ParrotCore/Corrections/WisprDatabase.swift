import Foundation
import SQLite3

enum WisprError: Error, CustomStringConvertible {
    case missing(String)
    case open(String)
    case query(String)

    var description: String {
        switch self {
        case .missing(let path): return "no Wispr Flow database at \(path)"
        case .open(let message): return "couldn't open the Wispr Flow database: \(message)"
        case .query(let message): return "couldn't read the Wispr Flow database: \(message)"
        }
    }
}

/// Wispr Flow's local database, opened read-only (ADR-006).
///
/// While Wispr Flow runs, the database has a write-ahead log, and Parrot
/// opens it as an ordinary reader (`mode=ro`): SQLite may touch the shared
/// index file, as every reader does, and never writes a page. When Wispr
/// Flow is quit there is no log, and Parrot opens the file as immutable,
/// which writes nothing at all. Every read runs in one transaction, so all
/// of them see one snapshot. Nothing is copied to disk, and text stays in
/// memory.
final class WisprDatabase {
    /// One row of Wispr's dictionary.
    struct DictionaryRow: Equatable {
        /// The spelling the user wants (Wispr's `phrase`).
        var phrase: String
        /// What Wispr had written when it learned the word from an edit.
        var observed: String?
        /// For a replacement: what to write when the user says `phrase`.
        var replacement: String?
        var manual: Bool
        var snippet: Bool
        /// How often Wispr used the entry.
        var uses: Int
    }

    /// One dictation: what Wispr pasted and what the field held after the
    /// user's edits, if Wispr saw any.
    struct Dictation {
        var pasted: String
        var edited: String?
    }

    private var db: OpaquePointer?

    init(file: URL = Paths.wisprDatabase) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw WisprError.missing(file.path) }
        let live = FileManager.default.fileExists(atPath: file.path + "-wal")
        let uri = file.absoluteString + (live ? "?mode=ro" : "?immutable=1")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(db)
            db = nil
            throw WisprError.open(message)
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("BEGIN")
    }

    deinit {
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_close_v2(db)
    }

    /// The personal dictionary, without deleted rows or team dictionaries.
    func dictionary() throws -> [DictionaryRow] {
        let columns = try columns(of: "Dictionary")
        guard columns.contains("phrase") else { return [] }
        func column(_ name: String, _ fallback: String) -> String { columns.contains(name) ? name : fallback }
        var conditions: [String] = []
        if columns.contains("isDeleted") { conditions.append("isDeleted = 0") }
        if columns.contains("teamDictionaryId") { conditions.append("teamDictionaryId = '00000000-0000-0000-0000-000000000000'") }
        let sql = """
            SELECT phrase, \(column("observedSource", "NULL")), \(column("replacement", "NULL")),
                   \(column("manualEntry", "0")), \(column("isSnippet", "0")), \(column("frequencyUsed", "0")),
                   \(column("source", "NULL"))
            FROM Dictionary \(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "))
            """
        var rows: [DictionaryRow] = []
        try query(sql) { s in
            guard let phrase = Self.text(s, 0), !phrase.isEmpty else { return }
            rows.append(DictionaryRow(
                phrase: phrase,
                observed: Self.text(s, 1).flatMap { $0.isEmpty ? nil : $0 },
                replacement: Self.text(s, 2).flatMap { $0.isEmpty ? nil : $0 },
                manual: sqlite3_column_int(s, 3) != 0 || Self.text(s, 6) == "manual",
                snippet: sqlite3_column_int(s, 4) != 0,
                uses: Int(sqlite3_column_int64(s, 5))
            ))
        }
        return rows
    }

    /// Every dictation with the text Wispr pasted.
    func dictations() throws -> [Dictation] {
        let columns = try columns(of: "History")
        guard columns.contains("formattedText") else { return [] }
        let pasted = columns.contains("pastedText") ? "COALESCE(NULLIF(pastedText, ''), formattedText)" : "formattedText"
        let edited = columns.contains("editedText") ? "NULLIF(editedText, '')" : "NULL"
        var result: [Dictation] = []
        try query("SELECT \(pasted), \(edited) FROM History WHERE \(pasted) IS NOT NULL") { s in
            guard let text = Self.text(s, 0), !text.isEmpty else { return }
            result.append(Dictation(pasted: text, edited: Self.text(s, 1)))
        }
        return result
    }

    /// Each dictation that still has its audio, oldest first: the WAV bytes
    /// and the text the user kept. One clip at a time, in memory.
    func forEachClip(_ body: (_ wav: Data, _ kept: String) throws -> Void) throws {
        let columns = try columns(of: "History")
        guard columns.contains("audio"), columns.contains("formattedText") else { return }
        let kept = [columns.contains("editedText") ? "NULLIF(editedText, '')" : nil,
                    columns.contains("pastedText") ? "NULLIF(pastedText, '')" : nil,
                    "formattedText"].compactMap { $0 }.joined(separator: ", ")
        let order = columns.contains("timestamp") ? "ORDER BY timestamp" : ""
        try query("SELECT audio, COALESCE(\(kept)) FROM History WHERE audio IS NOT NULL AND length(audio) > 44 \(order)") { s in
            guard let bytes = sqlite3_column_blob(s, 0), let text = Self.text(s, 1), !text.isEmpty else { return }
            try body(Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0))), text)
        }
    }

    // MARK: - SQLite

    private func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("PRAGMA table_info(\(table))") { s in
            if let name = Self.text(s, 1) { names.insert(name) }
        }
        return names
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw WisprError.query(errorMessage) }
    }

    private func query(_ sql: String, _ row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WisprError.query(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw WisprError.query(errorMessage)
            }
        }
    }

    private var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }
}
