import Foundation

/// A transcript that was not inserted at the cursor, with the line the
/// overlay shows.
enum DeliveryError: UserFacingError, Equatable {
    /// A password field had focus at start or at delivery. Nothing was typed
    /// or copied.
    case secureField
    /// Focus moved during the dictation. The transcript is on the clipboard.
    case focusChanged

    var userMessage: String {
        switch self {
        case .secureField: return "password field, transcript discarded"
        case .focusChanged: return "focus changed, transcript copied"
        }
    }
}

/// Where a finished transcript goes. Pure, so it is tested.
enum DeliveryDecision: Equatable {
    /// Insert at the cursor.
    case inject
    /// A secure field had focus at start or at delivery: drop the transcript.
    case discardSecure
    /// Focus moved: leave the transcript on the clipboard instead.
    case copyToClipboard

    /// `start` is nil when no recording start was seen; then only the
    /// secure-field check applies.
    static func decide(start: FocusSnapshot?, now: FocusSnapshot) -> DeliveryDecision {
        if start?.isSecure == true || now.isSecure { return .discardSecure }
        if let start, start.hasChanged(to: now) { return .copyToClipboard }
        return .inject
    }
}

/// The delivery step of the dictation loop: checks focus against the
/// snapshot from recording start, then injects, copies or discards. An
/// injected transcript gets a trailing space, and a leading one when the
/// text before the cursor needs it (`Spacing`).
@MainActor
final class TextDelivery {
    private let injector: TextInjector
    /// Fork (ADR-006): called after each paste at the cursor, for the edit
    /// watcher. Never called for a clipboard fallback or a secure field.
    var onInjected: ((InjectedText) -> Void)?

    init(mode: InjectMode) {
        self.injector = TextInjector(mode: mode)
    }

    /// Throws `DeliveryError` when the transcript did not reach the cursor.
    func deliver(_ text: String, focusAtStart: FocusSnapshot?) throws {
        guard !text.isEmpty else { return }
        let now = FocusSnapshot.capture()
        switch DeliveryDecision.decide(start: focusAtStart, now: now) {
        case .inject:
            let before = now.element?.textBeforeCursor() ?? .unknown
            let spaced = Spacing.spaced(text, before: before)
            // The kind of character only: the log never carries text.
            Log.info("  before cursor: \(before.kind)\(spaced.first == " " && text.first != " " ? " · leading space" : "")")
            let selection = onInjected == nil ? nil : now.element?.selectedRange()
            injector.inject(spaced)
            if let onInjected, let element = now.element {
                onInjected(InjectedText(text: spaced, pid: now.pid, element: element, selectionBefore: selection))
            }
        case .discardSecure:
            let when = focusAtStart?.isSecure == true ? "recording start" : "delivery"
            Log.info("  secure field focused at \(when); transcript discarded")
            throw DeliveryError.secureField
        case .copyToClipboard:
            injector.copyToClipboard(text)
            Log.info("  focus changed during dictation; transcript copied to clipboard")
            throw DeliveryError.focusChanged
        }
    }
}
