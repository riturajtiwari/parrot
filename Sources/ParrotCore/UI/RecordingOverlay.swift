import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the dictation loop as a `DictationObserver`.
///
/// Besides the recording and transcribing states, the pill can show a
/// one-line message (`showMessage`). A `UserFacingError` reaching
/// `dictationFailed` is shown that way; any other error just hides the pill.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
        /// One line of text, for example why a recording failed.
        case message(String)
    }

    /// How long a message stays up unless another state replaces it.
    nonisolated static let messageDuration: TimeInterval = 4

    /// Wide enough for a one-line message; the panel is transparent and
    /// click-through, so the unused width is invisible. Taller than the pill
    /// so its SwiftUI shadow is not clipped.
    private static let panelSize = NSSize(width: 640, height: 64)

    /// How long the pill takes to grow or shrink; on hide, the window is
    /// ordered out once it has.
    nonisolated static let scaleDuration: TimeInterval = 0.3

    init() {
        // Build the panel now, not on the first press, so the first pill
        // appears as quickly as every later one.
        ensureWindow()
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    /// Bumped by every `show`, so a message timer only hides its own message.
    private var generation = 0

    func show(_ state: State) {
        generation += 1
        ensureWindow()
        if state == .recording {
            model.resetLevels()
        }

        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away. Skip it if something was
        // shown again in the meantime.
        let window = self.window
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scaleDuration) {
            guard model.state == .hidden else { return }
            window?.orderOut(nil)
        }
    }

    /// Shows `text` on one line in the pill for `duration` seconds, then
    /// hides it, unless another state has replaced it by then. Never pass
    /// transcript text.
    func showMessage(_ text: String, for duration: TimeInterval = RecordingOverlay.messageDuration) {
        show(.message(text))
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.hide()
            }
        }
    }

    /// The message to show for a failed dictation, or nil to just hide.
    nonisolated static func message(for error: Error) -> String? {
        (error as? UserFacingError)?.userMessage
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The pill draws its own shadow. A window shadow is computed from the
        // window's contents when it is shown, so it would not follow the pill
        // as it grows and shrinks, and would linger after it had gone.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        // Keep the panel its fixed size and let SwiftUI center the pill in it,
        // so a wider message grows both ways instead of off to the right.
        host.sizingOptions = []
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        // The pill sits 32 pt above the bottom of the visible frame; the
        // panel extends below it by half its extra height.
        let y = visible.minY + 32 - (frame.height - 44) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

extension RecordingOverlay: DictationObserver {
    func dictationStarted() {
        show(.recording)
    }

    func dictationTranscribing() {
        show(.transcribing)
    }

    func dictationFinished(_ result: DictationResult) {
        hide()
    }

    func dictationFailed(_ error: Error) {
        if let text = Self.message(for: error) {
            showMessage(text)
        } else {
            hide()
        }
    }
}

/// Observable state for the SwiftUI pill.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 6
    /// Per-bar height multiplier — center bars peak higher than edge bars.
    private static let envelope: [Float] = [0.55, 0.85, 1.0, 1.0, 0.85, 0.55]

    @Published var state: RecordingOverlay.State = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)
    /// Whether the current recording has been louder than silence, so a
    /// recording with nothing said gets no loading animation.
    @Published private(set) var heardVoice = false

    /// RMS over one refresh interval above which the recording counts as
    /// speech. Silent recordings measure about 0.001 over their whole length;
    /// speech averages 0.007 to 0.018 and peaks well above.
    static let voiceThreshold: Float = 0.01

    /// How often the bars move. Capture delivers a level per buffer, about
    /// every 12 ms with the AUHAL input (#52); the bars are tuned for about
    /// 100 ms and look twitchy any faster.
    static let refreshInterval: TimeInterval = 0.1

    private var pendingPower: Float = 0
    private var pendingCount = 0
    private var lastRefresh: TimeInterval = 0

    /// Collects levels and moves the bars once per `refreshInterval`, with
    /// the RMS over that interval.
    func pushLevel(_ level: Float) {
        pendingPower += level * level
        pendingCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRefresh >= Self.refreshInterval else { return }
        let rms = (pendingPower / Float(pendingCount)).squareRoot()
        pendingPower = 0
        pendingCount = 0
        lastRefresh = now
        if rms > Self.voiceThreshold, !heardVoice {
            heardVoice = true
        }
        showLevel(rms)
    }

    private func showLevel(_ level: Float) {
        let shaped = min(1.0, sqrt(max(0, level)) * 3.4)
        var next = [Float]()
        next.reserveCapacity(Self.barCount)
        for i in 0..<Self.barCount {
            // Small per-bar jitter so the bars don't all move in lockstep.
            let jitter = Float.random(in: 0.78...1.0)
            next.append(shaped * Self.envelope[i] * jitter)
        }
        levels = next
    }

    func resetLevels() {
        pendingPower = 0
        pendingCount = 0
        heardVoice = false
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 16/255, green: 18/255, blue: 18/255))
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
            )
            // A faint light rim, like the edge of a macOS window, so the pill
            // holds its shape on a dark background.
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .scaleEffect(model.state == .hidden ? 0 : 1)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: RecordingOverlay.scaleDuration),
                value: model.state
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden, .recording, .transcribing:
            // The same bars in both states, so transcribing is the recording
            // bars taking up the loop rather than a swap to a spinner.
            Waveform(
                levels: model.levels,
                transcribing: model.state == .transcribing,
                heardVoice: model.heardVoice
            )
                .frame(width: 51, height: 20)
        case .message(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 235/255, green: 238/255, blue: 242/255))
                .lineLimit(1)
                .fixedSize()
                .frame(height: 20)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    var transcribing = false
    var heardVoice = false
    private let color = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)

    /// Height of an idle bar after a silent recording, as a fraction of the
    /// full height.
    private static let restHeight: CGFloat = 0.2
    /// Size of the dots the middle bars settle into while transcribing.
    private static let dotSize: CGFloat = 3.5
    /// How long the bars take to settle into dots.
    private static let settleDuration = 0.25

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3.75) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    let bar = bar(i, level: level, height: geo.size.height)
                    Capsule()
                        .fill(color)
                        .frame(width: bar.width, height: bar.height)
                        .opacity(bar.opacity)
                        .animation(
                            transcribing ? .easeInOut(duration: Self.settleDuration) : .easeOut(duration: 0.09),
                            value: bar.height
                        )
                        .animation(.easeInOut(duration: Self.settleDuration), value: bar.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// While recording, each bar follows the level. While transcribing, the
    /// outer bars fade where they stand and the middle ones settle into dots;
    /// after a silent recording, every bar just rests.
    private func bar(_ i: Int, level: Float, height: CGFloat) -> (width: CGFloat, height: CGFloat, opacity: Double) {
        let live = max(0.10, CGFloat(level)) * height
        guard transcribing else { return (2.5, live, 1) }
        guard heardVoice else { return (2.5, Self.restHeight * height, 1) }
        if i == 0 || i == levels.count - 1 {
            return (2.5, live, 0)
        }
        return (Self.dotSize, Self.dotSize, 1)
    }
}
