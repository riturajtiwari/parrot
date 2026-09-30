import AppKit
import ApplicationServices
import Foundation
import ParrotCore

/// Flags for `parrot-bench ax-probe`.
struct AXProbeOptions {
    /// How long to watch the focused element.
    var seconds: Double
    /// Seconds between two looks at the focused element.
    var interval: Double
}

/// What one app's focused text element offers over Accessibility, for the
/// edit watcher (ADR-006): which reads work, and whether the app sends
/// value-changed notifications. Holds flags and counts only, never text.
struct AXCapabilities: Equatable {
    var app: String
    var role: String
    var samples = 0
    var secure = false
    var valueReadable = false
    var valueSettable = false
    var characterCount = false
    var selectedRange = false
    /// The caret reads 0 while the field has text, as terminals report.
    var caretStuckAtZero = false
    var stringForRange = false
    var placeholder = false
    var valueChanged = 0
    var selectionChanged = 0

    /// One table row, with a tick or a dash per capability.
    var row: String {
        func mark(_ on: Bool) -> String { on ? "✓" : "–" }
        let columns = [
            app.padding(toLength: 34, withPad: " ", startingAt: 0),
            role.padding(toLength: 26, withPad: " ", startingAt: 0),
            String(samples).leftPadded(4),
            mark(secure), mark(valueReadable), mark(valueSettable), mark(characterCount),
            mark(selectedRange), mark(caretStuckAtZero), mark(stringForRange), mark(placeholder),
            String(valueChanged).leftPadded(4), String(selectionChanged).leftPadded(4),
        ]
        return columns.joined(separator: " ")
    }

    static let header = [
        "app".padding(toLength: 34, withPad: " ", startingAt: 0),
        "role/subrole".padding(toLength: 26, withPad: " ", startingAt: 0),
        "   n", "sec", "val", "set", "cnt", "rng", "@0", "sfr", "ph", "Δval", "Δsel",
    ].joined(separator: " ")
}

/// Watches whatever text element has focus while you click through your
/// apps and type a few characters in each, then prints what each app's
/// element supports. Never reads text into the output: only flags, counts
/// and the app's bundle identifier.
enum AXProbe {
    static func run(_ options: AXProbeOptions) throws {
        guard AXIsProcessTrusted() else {
            print("Accessibility is off for this terminal. Turn it on in System Settings → Privacy & Security → Accessibility, then run this again.")
            throw SilentExit(1)
        }
        print("For \(Int(options.seconds)) s: click into a text field in each app you use, and type a few characters there.")
        print("Nothing you type is read into the output.\n")

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        let watcher = NotificationCounter()
        var found: [String: AXCapabilities] = [:]
        var order: [String] = []
        var lastElement: AXUIElement?

        let end = Date().addingTimeInterval(options.seconds)
        while Date() < end {
            // Runs the observers' callbacks between two looks.
            CFRunLoopRunInMode(.defaultMode, options.interval, false)
            guard let element = focusedElement(systemWide) else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
            let role = [string(element, kAXRoleAttribute), string(element, kAXSubroleAttribute)]
                .compactMap { $0 }.joined(separator: "/")
            let key = app + " " + role
            if found[key] == nil {
                found[key] = AXCapabilities(app: app, role: role)
                order.append(key)
            }
            if lastElement.map({ !CFEqual($0, element) }) ?? true {
                watcher.watch(element, pid: pid, key: key)
                lastElement = element
            }
            found[key]?.merge(probe(element))
        }

        for key in order {
            found[key]?.valueChanged = watcher.count(key, kAXValueChangedNotification)
            found[key]?.selectionChanged = watcher.count(key, kAXSelectedTextChangedNotification)
        }
        print(AXCapabilities.header)
        for key in order { if let row = found[key]?.row { print(row) } }
        print("""

            sec: secure field · val: AXValue readable · set: AXValue settable · cnt: AXNumberOfCharacters
            rng: AXSelectedTextRange · @0: caret reads 0 in a field with text · sfr: AXStringForRange
            ph: AXPlaceholderValue · Δval, Δsel: value-changed and selection-changed notifications
            """)
    }

    private static func focusedElement(_ systemWide: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// One look at `element`. Reads values only to test that the read
    /// works; lengths and flags leave this function, text never does.
    private static func probe(_ element: AXUIElement) -> AXCapabilities {
        var result = AXCapabilities(app: "", role: "")
        result.samples = 1
        result.secure = string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String
            || bool(element, NSAccessibility.Attribute.containsProtectedContent.rawValue) == true
        guard !result.secure else { return result }

        var value: CFTypeRef?
        let valueLength: Int?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String {
            valueLength = text.utf16.count
            result.valueReadable = true
        } else {
            valueLength = nil
        }
        var settable: DarwinBoolean = false
        result.valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue

        var count: CFTypeRef?
        result.characterCount = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success
            && count is Int

        var rangeValue: CFTypeRef?
        var range = CFRange()
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
           AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
            result.selectedRange = true
            result.caretStuckAtZero = range.location == 0 && (valueLength ?? 0) > 0
        }

        let length = min(max(valueLength ?? 1, 1), 2)
        var probeRange = CFRange(location: max(range.location - length, 0), length: length)
        var text: CFTypeRef?
        if let query = AXValueCreate(.cfRange, &probeRange) {
            result.stringForRange = AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, query, &text
            ) == .success && text is String
        }
        result.placeholder = string(element, kAXPlaceholderValueAttribute) != nil
        return result
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}

extension AXCapabilities {
    /// Adds one look: a capability counts once any look saw it.
    mutating func merge(_ look: AXCapabilities) {
        samples += look.samples
        secure = secure || look.secure
        valueReadable = valueReadable || look.valueReadable
        valueSettable = valueSettable || look.valueSettable
        characterCount = characterCount || look.characterCount
        selectedRange = selectedRange || look.selectedRange
        caretStuckAtZero = caretStuckAtZero || look.caretStuckAtZero
        stringForRange = stringForRange || look.stringForRange
        placeholder = placeholder || look.placeholder
    }
}

/// Counts value-changed and selection-changed notifications per probe key,
/// with one `AXObserver` per app.
private final class NotificationCounter {
    private var observers: [pid_t: AXObserver] = [:]
    private var counts: [String: Int] = [:]
    /// The key of each watched element's notifications, by the element.
    private var keys: [(element: AXUIElement, key: String)] = []

    func watch(_ element: AXUIElement, pid: pid_t, key: String) {
        guard let observer = observer(for: pid) else { return }
        keys.append((element, key))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    func count(_ key: String, _ notification: String) -> Int {
        counts[key + "|" + notification] ?? 0
    }

    fileprivate func record(_ element: AXUIElement, _ notification: String) {
        guard let key = keys.last(where: { CFEqual($0.element, element) })?.key else { return }
        counts[key + "|" + notification, default: 0] += 1
    }

    private func observer(for pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<NotificationCounter>.fromOpaque(refcon).takeUnretainedValue()
                .record(element, notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        return observer
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
