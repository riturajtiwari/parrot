import Foundation

/// Where a dictation's dictionary comes from: one file, or the user's file
/// with Parrot's learned overlay after it.
package protocol DictionarySource: AnyObject, Sendable {
    /// The dictionary to use for this dictation, reloaded first if a file
    /// changed.
    func current() -> DictionaryStore.Loaded
}

extension DictionaryStore: DictionarySource {}

/// The user's dictionary with Parrot's learned overlay after it (ADR-006).
///
/// The user's rows win: an overlay row for a word the user already has, and
/// an overlay item the user's file already uses as a word or an item, are
/// left out. So an automatic add can never change what the user wrote.
package final class LayeredDictionary: DictionarySource, @unchecked Sendable {
    let base: DictionaryStore
    let overlay: DictionaryStore
    private let lock = NSLock()
    private var cache: (base: UserDictionary, overlay: UserDictionary, loaded: DictionaryStore.Loaded)?

    package init(base: DictionaryStore = DictionaryStore(), overlay: DictionaryStore = DictionaryStore(file: Paths.learnedDictionaryFile)) {
        self.base = base
        self.overlay = overlay
    }

    package func current() -> DictionaryStore.Loaded {
        let mine = base.current().dictionary
        let learned = overlay.current().dictionary
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.base == mine, cache.overlay == learned { return cache.loaded }
        let loaded = DictionaryStore.Loaded(Self.merged(mine, learned))
        cache = (mine, learned, loaded)
        return loaded
    }

    /// The replacement pass, for tools outside ParrotCore such as
    /// `parrot-bench`.
    package func apply(to text: String) -> String {
        current().replacer.apply(to: text)
    }

    /// Every word the merged dictionary spells, for tools that score it.
    package var words: [String] {
        current().dictionary.terms
    }

    /// `base` followed by what `overlay` adds without touching `base`.
    static func merged(_ base: UserDictionary, _ overlay: UserDictionary) -> UserDictionary {
        guard overlay != .empty else { return base }
        var taken = Set(base.terms.map { $0.lowercased() })
        for replacement in base.replacements {
            taken.insert(replacement.to.lowercased())
            taken.formUnion(replacement.from.map { $0.lowercased() })
        }
        var result = base
        for term in overlay.terms where !taken.contains(term.lowercased()) {
            result.terms.append(term)
        }
        for replacement in overlay.replacements where !taken.contains(replacement.to.lowercased()) {
            let from = replacement.from.filter { !taken.contains($0.lowercased()) }
            if !from.isEmpty { result.replacements.append(.init(from: from, to: replacement.to)) }
        }
        return result
    }
}
