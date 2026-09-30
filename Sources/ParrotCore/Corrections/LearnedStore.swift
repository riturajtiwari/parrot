import Foundation

/// One learned pair and what happened to it (ADR-006). Holds a few words,
/// never a sentence.
struct LearnedPair: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Waits for the user's decision.
        case pending
        /// Its rows are in a dictionary.
        case added
        /// The user said no. Parrot never proposes it again.
        case rejected
        /// The user reverted what one of its rows wrote.
        case suspect
    }

    enum Source: String, Codable, Sendable, Comparable {
        case wisprDictionary = "wispr-dictionary"
        case wisprEdits = "wispr-edits"
        case whisper
        case watched
        case fixWord = "fix-word"

        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where the pair's rows were written.
    enum Target: String, Codable, Sendable {
        case dictionary, overlay
    }

    /// The spelling the user wants.
    var word: String
    /// What the model wrote instead, or nil for a word with no heard form.
    var heard: String?
    /// The rules the user accepted, or the rules proposed while pending.
    var rules: [CorrectionRule]
    var status: Status
    var sources: [Source]
    /// Times the pair was seen.
    var seen: Int
    var firstSeen: Date
    var lastSeen: Date
    var decided: Date?
    var target: Target?
    /// Parrot created the word's row, so Undo removes the whole row. When
    /// the row was there before, Undo removes only the heard form.
    var createdRow: Bool?
    /// The rules first proposed, kept after the user decides, so the hybrid
    /// gate can measure how often the proposals were right.
    var proposed: [CorrectionRule]?

    /// The identity of a pair: the word and the heard form, in any case.
    var key: String { Self.key(word: word, heard: heard) }

    static func key(word: String, heard: String?) -> String {
        word.lowercased() + "\u{1F}" + (heard?.lowercased() ?? "")
    }

    /// At most `WordDiff.maxWords` words and 64 characters a side, so the
    /// file can never hold a sentence.
    static func isStorable(_ text: String) -> Bool {
        text.count <= 64 && text.split(whereSeparator: \.isWhitespace).count <= WordDiff.maxWords && !text.contains("\n")
    }
}

/// `corrections.json`: every learned pair with its status (ADR-006).
struct LearnedPairs: Codable, Equatable, Sendable {
    var version = 1
    var pairs: [LearnedPair] = []

    func pair(word: String, heard: String?) -> LearnedPair? {
        let key = LearnedPair.key(word: word, heard: heard)
        return pairs.first { $0.key == key }
    }

    /// Records `pair`, or adds its evidence to the one already there. A
    /// decided pair keeps its decision.
    mutating func record(_ pair: LearnedPair) {
        if let index = pairs.firstIndex(where: { $0.key == pair.key }) {
            pairs[index].seen = max(pairs[index].seen, pair.seen)
            pairs[index].sources = Array(Set(pairs[index].sources + pair.sources)).sorted()
            pairs[index].lastSeen = max(pairs[index].lastSeen, pair.lastSeen)
            if pairs[index].status == .pending {
                pairs[index].rules = pair.rules
                pairs[index].proposed = pair.proposed ?? pair.rules
            }
        } else {
            var pair = pair
            if pair.proposed == nil { pair.proposed = pair.rules }
            pairs.append(pair)
        }
    }

    mutating func decide(
        word: String, heard: String?, status: LearnedPair.Status, rules: [CorrectionRule],
        target: LearnedPair.Target?, createdRow: Bool? = nil, at date: Date = Date()
    ) {
        let key = LearnedPair.key(word: word, heard: heard)
        guard let index = pairs.firstIndex(where: { $0.key == key }) else { return }
        pairs[index].status = status
        pairs[index].rules = rules.sorted()
        pairs[index].target = target
        pairs[index].decided = date
        if let createdRow { pairs[index].createdRow = createdRow }
    }
}

enum LearnedStoreError: Error, Equatable, CustomStringConvertible {
    case notStorable
    case unreadable(String)

    var description: String {
        switch self {
        case .notStorable: return "a pair has more than 3 words or 64 characters on a side"
        case .unreadable(let message): return message
        }
    }
}

/// Reads and writes `corrections.json` under a lock, owner-only, with an
/// atomic rename, so the app and the CLI never lose each other's updates.
struct LearnedStore {
    let file: URL
    let lock: URL

    init(file: URL = Paths.correctionsFile, lock: URL? = nil) {
        self.file = file
        self.lock = lock ?? file.deletingLastPathComponent().appendingPathComponent("corrections.lock")
    }

    func load() throws -> LearnedPairs {
        guard Paths.fileType(file.path) != nil else { return LearnedPairs() }
        guard Paths.fileType(file.path) == .typeRegular else { throw LearnedStoreError.unreadable("\(file.path) is not a regular file") }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LearnedPairs.self, from: Data(contentsOf: file))
        } catch {
            throw LearnedStoreError.unreadable("\(file.lastPathComponent) doesn't parse: \(error.localizedDescription)")
        }
    }

    /// Loads the file, lets `body` change it, validates, and saves it.
    @discardableResult
    func update<T>(_ body: (inout LearnedPairs) throws -> T) throws -> T {
        try Paths.prepareDirectory(file.deletingLastPathComponent())
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LearnedStoreError.unreadable("couldn't open \(lock.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LearnedStoreError.unreadable("couldn't lock \(lock.path)") }
        defer { flock(fd, LOCK_UN) }

        var pairs = try load()
        let result = try body(&pairs)
        guard pairs.pairs.allSatisfy({ LearnedPair.isStorable($0.word) && ($0.heard.map(LearnedPair.isStorable) ?? true) }) else {
            throw LearnedStoreError.notStorable
        }
        try save(pairs)
        return result
    }

    private func save(_ pairs: LearnedPairs) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pairs) + Data("\n".utf8)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LearnedStoreError.unreadable("couldn't create \(temporary.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else {
                throw LearnedStoreError.unreadable("couldn't replace \(file.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}
