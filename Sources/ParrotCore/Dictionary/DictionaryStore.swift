import Foundation

/// Loads the dictionary file (`Paths.dictionaryFile`, a plain-text table) and
/// reloads it when it changes, without a restart.
///
/// `current()` is called before each dictation. It stats the file and reads
/// it again only when the file's identity, size or modification time changed.
/// A file that fails to load keeps the last good dictionary and logs one line
/// naming the problem; the line is not repeated until the file changes again.
///
/// The file may live in a dotfiles repository: `~/.config/parrot`, or the file
/// itself, can be a symlink. The store resolves the path and then requires the
/// target to be a regular file owned by the current user. It never changes the
/// directory's permissions (`Paths.prepareDirectory` refuses symlinks, which is
/// right for logs and wrong here).
package final class DictionaryStore: @unchecked Sendable {
    /// A dictionary with its compiled replacement pass. `package` so that
    /// `DictionarySource` can return it.
    package struct Loaded {
        let dictionary: UserDictionary
        let replacer: DictionaryReplacer

        init(_ dictionary: UserDictionary) {
            self.dictionary = dictionary
            self.replacer = DictionaryReplacer(dictionary)
        }
    }

    /// Larger than any hand-written dictionary; refuses anything absurd.
    static let maxBytes = 1 << 20

    let file: URL
    private let log: (String) -> Void
    private let lock = NSLock()
    private var loaded = Loaded(.empty)
    /// What was last looked at, loaded or not, so an unchanged file is neither
    /// read nor logged again.
    private var seen: Stamp?

    package init(file: URL = Paths.dictionaryFile, log: @escaping (String) -> Void = { Log.warning($0) }) {
        self.file = file
        self.log = log
    }

    /// The dictionary to use for this dictation, reloaded first if the file
    /// changed.
    package func current() -> Loaded {
        lock.lock()
        defer { lock.unlock() }
        refresh()
        return loaded
    }

    /// Writes the first-run template when nothing at all exists at the path:
    /// not a file, not a symlink (even a dangling one). Creates the config
    /// directory owner-only if it is missing, and never touches an existing one.
    /// Returns true if it wrote the file.
    @discardableResult
    func createIfMissing() -> Bool {
        let fm = FileManager.default
        guard Paths.fileType(file.path) == nil else { return false }
        let dir = file.deletingLastPathComponent()
        do {
            if Paths.fileType(dir.path) == nil {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            log("couldn't create \(dir.path): \(error.localizedDescription)")
            return false
        }
        // O_EXCL | O_NOFOLLOW: never write through something that appeared
        // after the check.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno != EEXIST {
                log("couldn't create \(file.path): \(String(cString: strerror(errno)))")
            }
            return false
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(UserDictionary.template.utf8))
        } catch {
            log("couldn't write \(file.path): \(error.localizedDescription)")
            return false
        }
        Log.info("created \(file.path) with an example row")
        return true
    }

    // MARK: - Reloading

    /// Identity and version of the file last looked at.
    private enum Stamp: Equatable {
        case missing
        case refused(String)
        case file(path: String, device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int)
    }

    private func refresh() {
        // Nothing at the path: the user removed their dictionary, so use none.
        guard Paths.fileType(file.path) != nil else {
            if seen != .missing {
                if seen != nil { log("\(file.path) was removed; dictionary is empty") }
                loaded = Loaded(.empty)
                seen = .missing
            }
            return
        }

        let resolved = file.resolvingSymlinksInPath().path
        var st = stat()
        guard stat(resolved, &st) == 0 else {
            return refuse("\(file.path) points to \(resolved), which doesn't exist")
        }
        if let problem = Self.problem(with: st, at: resolved) {
            return refuse(problem)
        }
        let stamp = Self.stamp(resolved, st)
        if stamp == seen { return }

        // Read through a descriptor and check it again, so the file checked is
        // the file read even if the path is swapped in between.
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            return refuse("couldn't open \(resolved): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &st) == 0 else { return refuse("couldn't read \(resolved)") }
        if let problem = Self.problem(with: st, at: resolved) {
            return refuse(problem)
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return refuse("couldn't read \(resolved): \(error.localizedDescription)")
        }

        seen = Self.stamp(resolved, st)
        do {
            let dictionary = try UserDictionary.parse(data)
            loaded = Loaded(dictionary)
            Log.info("dictionary: \(dictionary.terms.count) words · \(dictionary.replacements.count) with replacements")
        } catch {
            log("\(file.lastPathComponent) not loaded, \(error); keeping the last good version")
        }
    }

    /// Keeps the last good dictionary and logs `message` once.
    private func refuse(_ message: String) {
        let stamp = Stamp.refused(message)
        guard seen != stamp else { return }
        seen = stamp
        log("\(message); keeping the last good dictionary")
    }

    /// Why the file at `path`, already resolved, can't be used, or nil.
    static func problem(with st: stat, at path: String) -> String? {
        if st.st_mode & S_IFMT != S_IFREG { return "\(path) is not a regular file" }
        if st.st_uid != getuid() { return "\(path) is not owned by you" }
        if st.st_size > maxBytes { return "\(path) is larger than \(maxBytes / 1024) KB" }
        return nil
    }

    private static func stamp(_ path: String, _ st: stat) -> Stamp {
        .file(
            path: path,
            device: st.st_dev,
            inode: st.st_ino,
            size: st.st_size,
            seconds: st.st_mtimespec.tv_sec,
            nanoseconds: st.st_mtimespec.tv_nsec
        )
    }
}
