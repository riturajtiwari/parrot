import AppKit
import ApplicationServices
import Foundation

/// Follows a field after each paste with Accessibility reads, and hands the
/// corrections it sees to `EditLearner` (ADR-006).
///
/// - Only in the apps of `watchedApps`, and never in a secure field:
///   `TextDelivery` calls it only after a paste at the cursor.
/// - Reads run on the watcher's own queue with a 0.1 s timeout per call,
///   never on the main thread, so a hung app can't delay the hotkey.
/// - No keystrokes: the event tap stays `flagsChanged` only (ADR-003).
/// - The pasted text stays in memory until the watch ends. Logs hold the
///   end reason and a count, never text.
@MainActor
final class EditWatcher: DictationObserver {
    private let queue = DispatchQueue(label: "parrot.edit-watcher", qos: .utility)
    private var session: WatchSession?
    private let settings: () -> CorrectionSettings
    private let learner: EditLearner

    init(settings: @escaping () -> CorrectionSettings, learner: EditLearner) {
        self.settings = settings
        self.learner = learner
    }

    func watch(_ injected: InjectedText) {
        session?.stop(.nextDictation)
        session = nil
        let settings = self.settings()
        guard settings.learning != .off, injected.text.contains(where: \.isLetter),
              let pid = injected.pid,
              let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              settings.watchedApps.contains(app) else { return }
        var limits = EditWatch.Limits()
        limits.total = TimeInterval(settings.watchSeconds)
        limits.maxChanges = settings.maxPerDictation
        let watch = EditWatch(
            pasted: injected.text,
            expected: (injected.selectionBefore?.location ?? 0) + Self.leadingSpaces(injected.text),
            at: ProcessInfo.processInfo.systemUptime,
            limits: limits
        )
        let learner = self.learner
        let session = WatchSession(element: injected.element.ref, watch: watch, queue: queue) { changes, reason in
            Log.info("edit watch: \(reason.rawValue) · \(changes.count) change(s)")
            guard !changes.isEmpty else { return }
            Task { @MainActor in await learner.learn(changes) }
        }
        self.session = session
        session.start()
    }

    func dictationStarted() {
        session?.stop(.nextDictation)
        session = nil
    }

    /// The spaces `Spacing` put before the transcript: the paste starts at
    /// the selection, the words after them.
    private static func leadingSpaces(_ text: String) -> Int {
        text.utf16.prefix(while: { $0 == 0x20 }).count
    }
}

/// One watch on the watcher's queue. Every mutable property is touched on
/// that queue only.
final class WatchSession: @unchecked Sendable {
    private let element: AXUIElement
    private var watch: EditWatch
    private let queue: DispatchQueue
    private let onEnd: ([WordChange], EditWatch.End) -> Void
    private var timer: DispatchSourceTimer?
    private var ended = false

    /// Fields longer than this are read as a window around the paste.
    static let wholeFieldLimit = 20_000

    init(element: AXUIElement, watch: EditWatch, queue: DispatchQueue, onEnd: @escaping ([WordChange], EditWatch.End) -> Void) {
        self.element = element
        self.watch = watch
        self.queue = queue
        self.onEnd = onEnd
        AXUIElementSetMessagingTimeout(element, 0.1)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // The app reads the pasted clipboard within `TextInjector.settleDelay`.
        timer.schedule(deadline: .now() + 0.3, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop(_ reason: EditWatch.End) {
        queue.async { [self] in
            guard !ended else { return }
            end(watch.finish(reason))
        }
    }

    private func tick() {
        guard !ended else { return }
        let step = watch.step(read(), at: ProcessInfo.processInfo.systemUptime)
        if case .ended = step { end(step) }
    }

    private func end(_ step: EditWatch.Step) {
        guard case .ended(let reason, let changes) = step else { return }
        ended = true
        timer?.cancel()
        timer = nil
        onEnd(changes, reason)
    }

    /// The field as it is now, or nil when the app doesn't say.
    private func read() -> FieldState? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focused = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success
            && focusedRef.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, element) } == true
        var placeholderRef: CFTypeRef?
        let placeholder = AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholderRef) == .success
            ? placeholderRef as? String : nil
        var countRef: CFTypeRef?
        let count = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success
            ? countRef as? Int : nil

        if count.map({ $0 <= Self.wholeFieldLimit }) ?? true {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                  let text = value as? String, (text as NSString).length <= Self.wholeFieldLimit else { return nil }
            return FieldState(text: text, offset: 0, focused: focused, placeholder: placeholder, reachesEnd: true)
        }
        // A long document: a window around the paste.
        guard let total = count else { return nil }
        let start = max(0, watch.expected - 1_000)
        var range = CFRange(location: start, length: min(total - start, (watch.pasted as NSString).length + 3_000))
        var text: CFTypeRef?
        guard let query = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, query, &text) == .success,
              let window = text as? String else { return nil }
        return FieldState(text: window, offset: start, focused: focused, placeholder: placeholder, reachesEnd: start + range.length >= total)
    }
}
