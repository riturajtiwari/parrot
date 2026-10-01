import AppKit
import SwiftUI

/// Which outcome of an edit the learning notice shows, and its words
/// (ADR-006). Pure, so it is tested.
enum LearningNoticePlan {
    enum Kind: Equatable {
        /// Added at once: Undo.
        case added
        /// Waits for the user: Add, Not this.
        case ask
        /// A learned rule was changed back: Review.
        case reverted
        /// Seen, nothing learned: no buttons, faint.
        case notLearned
    }

    struct Plan: Equatable {
        var kind: Kind
        var text: String
        var duration: TimeInterval
        /// The pair the buttons act on.
        var pair: LearnedPair?
    }

    /// The outcome that matters most (an add, then a question, then a
    /// revert, then a change Parrot passed over), with the count of other
    /// adds and questions, which wait in Review Corrections.
    static func plan(_ outcomes: [EditLearner.Outcome]) -> Plan? {
        func rank(_ outcome: EditLearner.Outcome) -> Int {
            switch outcome {
            case .added: return 0
            case .proposed: return 1
            case .reverted: return 2
            case .notLearned: return 3
            }
        }
        guard let first = outcomes.min(by: { rank($0) < rank($1) }) else { return nil }
        let actionable = outcomes.filter { rank($0) <= 1 }.count
        let more = rank(first) <= 1 ? actionable - 1 : actionable
        let tail = more > 0 ? " · \(more) more in Review" : ""
        switch first {
        case .added(let pair):
            return Plan(kind: .added, text: "Added “\(pair.word)” to your dictionary" + tail, duration: 4, pair: pair)
        case .proposed(let pair):
            let heard = pair.heard.map { "\($0) → " } ?? ""
            return Plan(kind: .ask, text: "Learn \(heard)\(pair.word)?" + tail, duration: 6, pair: pair)
        case .reverted(let pair):
            return Plan(kind: .reverted, text: "You changed back “\(pair.word)”. It waits in Review" + tail, duration: 4, pair: pair)
        case .notLearned(let reason):
            return Plan(kind: .notLearned, text: "Edit seen: nothing to learn (\(reason))" + tail, duration: 2, pair: nil)
        }
    }
}

/// The learning notice (ADR-006): a capsule above the recording pill that
/// says what Parrot made of an edit. Its buttons take clicks, but it never
/// takes focus, so the user keeps typing in their app. One at a time: a new
/// notice replaces the old one, and a dictation hides it. It shows a word
/// pair at most, which `corrections.json` already holds.
@MainActor
final class LearningNotice: DictationObserver {
    struct Action {
        let title: String
        var primary = false
        let run: () -> Void
    }

    struct Content {
        var symbol: String
        var text: String
        var actions: [Action] = []
        var duration: TimeInterval
        var faint = false
    }

    private var panel: NoticePanel?
    private var host: NoticeHostingView?
    private let model = NoticeModel()
    private var timer: Timer?
    private var deadline = Date.distantPast
    private var paused: TimeInterval?

    func show(_ content: Content) {
        let panel = ensurePanel()
        model.content = content
        host?.layoutSubtreeIfNeeded()
        if let size = host?.fittingSize, size.width > 0 {
            panel.setContentSize(size)
        }
        position(panel)
        panel.orderFrontRegardless()
        schedule(content.duration)
        // VoiceOver users hear it too.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: content.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        paused = nil
        model.content = nil
        panel?.orderOut(nil)
    }

    func dictationStarted() {
        hide()
    }

    // MARK: - Timing

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        paused = nil
        deadline = Date().addingTimeInterval(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// The pointer over the notice holds it open; leaving gives it at least
    /// 1.5 s more.
    private func hover(_ inside: Bool) {
        guard model.content != nil else { return }
        if inside {
            guard paused == nil else { return }
            paused = max(deadline.timeIntervalSinceNow, 0)
            timer?.invalidate()
            timer = nil
        } else if let left = paused {
            schedule(max(left, 1.5))
        }
    }

    private func perform(_ action: Action) {
        hide()
        action.run()
    }

    // MARK: - Window

    private func ensurePanel() -> NoticePanel {
        if let panel { return panel }
        let panel = NoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NoticeHostingView(rootView: NoticeCapsule(model: model, perform: { [weak self] action in self?.perform(action) }))
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel.contentView = host
        self.host = host
        self.panel = panel
        return panel
    }

    /// Centered, just above the recording pill (`RecordingOverlay`).
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 82))
    }
}

/// Takes clicks, never the keyboard: the user's app keeps its focus.
private final class NoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hands the first click straight to the buttons, and reports the pointer
/// entering and leaving, while Parrot is not the active app.
private final class NoticeHostingView: NSHostingView<NoticeCapsule> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
private final class NoticeModel: ObservableObject {
    @Published var content: LearningNotice.Content?
}

private struct NoticeCapsule: View {
    @ObservedObject var model: NoticeModel
    let perform: (LearningNotice.Action) -> Void

    var body: some View {
        if let content = model.content {
            HStack(spacing: 10) {
                Image(systemName: content.symbol).foregroundStyle(.secondary)
                Text(content.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(content.faint ? .secondary : .primary)
                ForEach(content.actions.indices, id: \.self) { index in
                    let action = content.actions[index]
                    Button(action.title) { perform(action) }
                        .buttonStyle(PillButtonStyle(primary: action.primary))
                }
            }
            .font(.system(size: 13))
            .padding(.leading, 14)
            .padding(.trailing, content.actions.isEmpty ? 14 : 6)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .fixedSize()
            .padding(4)
        }
    }
}
