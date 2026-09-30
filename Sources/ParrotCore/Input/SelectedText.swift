import ApplicationServices
import Foundation

extension FocusSnapshot {
    /// The text selected in the focused element, for Fix Word (ADR-006).
    /// Nil in a secure field, when nothing is selected, when the app doesn't
    /// say, or when the selection is longer than a few words: Fix Word
    /// learns a word, not a sentence.
    @MainActor
    static func selectedWords() -> String? {
        let focus = capture()
        guard !focus.isSecure, let element = focus.element?.ref else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, LearnedPair.isStorable(text) else { return nil }
        return text
    }
}

extension FocusedElement {
    /// The selection, in UTF-16 units, or nil when the app doesn't say.
    func selectedRange() -> CFRange? {
        var value: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(ref, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return range
    }
}

/// A transcript that was pasted at the cursor, for the edit watcher
/// (ADR-006). The text stays in memory.
struct InjectedText {
    /// What was pasted, with the spaces `Spacing` added.
    var text: String
    var pid: pid_t?
    var element: FocusedElement
    /// The selection before the paste, where the paste starts.
    var selectionBefore: CFRange?
}
