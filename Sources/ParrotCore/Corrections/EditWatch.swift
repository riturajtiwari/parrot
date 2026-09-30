import Foundation

/// What the edit watcher read from the field at one moment. `text` may be
/// the whole field or a window of it that starts at `offset` (UTF-16 units).
struct FieldState: Equatable {
    var text: String
    var offset: Int = 0
    /// The field still has keyboard focus.
    var focused = true
    /// What the field shows when it is empty, if the app says.
    var placeholder: String?
    /// `text` reaches the end of the field.
    var reachesEnd = true
}

/// The edit watcher's state machine (ADR-006), without Accessibility, so
/// tests can replay field states. Pure, and it holds text in memory only.
///
/// 1. Confirm: the pasted text must appear near where the paste started.
///    The first confirmed read is the baseline, because apps change what
///    they paste (smart quotes, links).
/// 2. Follow: find the region again between the text before and after it,
///    so text typed elsewhere in the field doesn't matter.
/// 3. End on the next dictation, a focus change, an emptied field (a sent
///    message), a lost anchor, a rewrite, idleness or the time limit. The
///    result compares the baseline with the last region that stayed the same
///    for two reads, never with a half-typed one.
struct EditWatch {
    enum End: String, Equatable {
        case nextDictation = "next dictation"
        case focusChanged = "focus changed"
        case emptied = "field emptied"
        case anchorLost = "anchor lost"
        case rewritten = "rewritten"
        case idle = "idle"
        case timeUp = "time up"
        case notFound = "paste not found"
    }

    enum Step: Equatable {
        case waiting
        case following
        case ended(End, [WordChange])
    }

    struct Limits {
        var confirm: TimeInterval = 1.5
        var idle: TimeInterval = 20
        var total: TimeInterval = 60
        /// Reads a region must stay the same to count as stable.
        var stableReads = 2
        /// Characters of anchor on each side of the region.
        var anchor = 32
        var maxChanges = 4
    }

    let pasted: String
    /// Where the paste started, in UTF-16 units of the field.
    let expected: Int
    let started: TimeInterval
    var limits: Limits

    private(set) var baseline: String?
    private var before = ""
    private var after = ""
    private var regionStart = 0
    private var regionReachesEnd = false
    private var last: String?
    private var stable: String?
    private var unchanged = 0
    private var lastChange: TimeInterval

    init(pasted: String, expected: Int, at now: TimeInterval, limits: Limits = Limits()) {
        self.pasted = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expected = expected
        self.started = now
        self.limits = limits
        self.lastChange = now
    }

    mutating func step(_ field: FieldState?, at now: TimeInterval) -> Step {
        guard let baseline else { return confirm(field, at: now) }
        guard let field else { return finish(.anchorLost) }
        if !field.focused { return finish(.focusChanged) }
        let text = field.text as NSString
        if field.offset == 0, field.reachesEnd,
           field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || field.text == field.placeholder {
            return finish(.emptied)
        }
        guard let region = locate(in: field) else { return finish(.anchorLost) }
        _ = text
        if WordDiff.keptShare(from: baseline, to: region) < 0.5 {
            return .ended(.rewritten, [])
        }
        if region == last {
            unchanged += 1
            if unchanged + 1 >= limits.stableReads { stable = region }
        } else {
            last = region
            unchanged = 0
            lastChange = now
        }
        if now - started >= limits.total { return finish(.timeUp) }
        if now - lastChange >= limits.idle, stable != nil { return finish(.idle) }
        return .following
    }

    /// Ends the watch from outside, for the next dictation.
    mutating func finish(_ reason: End) -> Step {
        guard let baseline, let final = stable, final != baseline else { return .ended(reason, []) }
        var changes = WordDiff.changes(from: baseline, to: final)
        // At the end of a field, words typed after the paste join the region:
        // a last change that grew may be new text, not a correction.
        if regionReachesEnd, let lastChange = changes.last, lastChange.corrected.count > lastChange.heard.count,
           WordDiff.words(final).last?.text == lastChange.corrected.last {
            changes.removeLast()
        }
        return .ended(reason, Array(changes.prefix(limits.maxChanges)))
    }

    // MARK: - Steps

    private mutating func confirm(_ field: FieldState?, at now: TimeInterval) -> Step {
        guard now - started <= limits.confirm else { return .ended(.notFound, []) }
        guard let field, !pasted.isEmpty else { return .waiting }
        let text = field.text as NSString
        guard let found = Self.nearest(pasted, in: text, offset: field.offset, around: expected),
              abs(found - expected) <= max(64, (pasted as NSString).length) else { return .waiting }
        let local = found - field.offset
        let length = (pasted as NSString).length
        let beforeStart = max(0, local - limits.anchor)
        before = text.substring(with: NSRange(location: beforeStart, length: local - beforeStart))
        let afterStart = local + length
        after = text.substring(with: NSRange(location: afterStart, length: min(limits.anchor, text.length - afterStart)))
        regionStart = found
        regionReachesEnd = after.isEmpty && field.reachesEnd
        baseline = pasted
        last = pasted
        stable = pasted
        lastChange = now
        return .following
    }

    /// The region between the anchors, or nil when an anchor is gone.
    private mutating func locate(in field: FieldState) -> String? {
        let text = field.text as NSString
        let end = field.offset + text.length
        var start = field.offset
        if !before.isEmpty {
            let expectedAnchor = regionStart - (before as NSString).length
            guard let at = Self.nearest(before, in: text, offset: field.offset, around: expectedAnchor) else { return nil }
            start = at + (before as NSString).length
        } else if regionStart > field.offset {
            start = regionStart
        }
        var stop = end
        if !after.isEmpty {
            let guess = start + ((last ?? pasted) as NSString).length
            guard let at = Self.nearest(after, in: text, offset: field.offset, around: guess), at >= start else { return nil }
            stop = at
        } else if !field.reachesEnd {
            return nil
        }
        regionStart = start
        let region = text.substring(with: NSRange(location: start - field.offset, length: stop - start))
        return region.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The absolute location of the occurrence of `needle` nearest to
    /// `around`, or nil when there is none.
    static func nearest(_ needle: String, in text: NSString, offset: Int, around: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        var best: Int?
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: needle, options: [.literal], range: search)
            guard found.location != NSNotFound else { break }
            let at = offset + found.location
            if best.map({ abs(at - around) < abs($0 - around) }) ?? true { best = at }
            let next = found.location + 1
            search = NSRange(location: next, length: text.length - next)
        }
        return best
    }
}
