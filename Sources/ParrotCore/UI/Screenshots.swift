import AppKit
import SwiftUI

/// Draws the fork's windows off-screen with made-up words, for the README
/// (`parrot-bench screenshots`). It reads nothing of the user's: not the
/// screen, not `settings.json`, not the Keychain, not `corrections.json`,
/// not the clipboard. Each scene comes out light and dark.
package enum Screenshots {
    enum Failure: Error, CustomStringConvertible {
        case render(String)

        var description: String {
            switch self {
            case .render(let name): return "couldn't draw \(name)"
            }
        }
    }

    /// Writes `<scene>-light.png` and `<scene>-dark.png` into `dir` and
    /// returns the files.
    @MainActor
    package static func write(to dir: URL) throws -> [URL] {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-screenshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = demoSettings(in: scratch)

        var files: [URL] = []
        for (name, view) in scenes(store) {
            for dark in [false, true] {
                let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try render(view, dark: dark, to: file)
                files.append(file)
            }
        }
        return files
    }

    // MARK: - Scenes

    @MainActor
    private static func scenes(_ store: SettingsStore) -> [(String, AnyView)] {
        [
            ("notice-ask", LearningNotice.preview(.init(symbol: "sparkles", text: "Learn Kwilbo → Qwilbo?", actions: [
                .init(title: "Add", primary: true) {}, .init(title: "Not this") {},
            ], duration: 6))),
            ("notice-added", LearningNotice.preview(.init(symbol: "book.closed", text: "Added “Qwilbo” to your dictionary", actions: [
                .init(title: "Undo") {},
            ], duration: 4))),
            ("settings-corrections", AnyView(
                CorrectionsSection(store: store, preview: .init(hasKey: true, pendingCount: 3, wisprAvailable: true,
                                                                gate: HybridGate.Status(decisions: 12, accepted: 11)))
                    .padding(.horizontal, 12)
                    .frame(width: 420)
            )),
            ("connect-model", AnyView(ConnectSheet(model: .preview(
                provider: .claude, store: store,
                models: ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"], recommended: "claude-haiku-4-5"
            )))),
            ("review", AnyView(ReviewView(model: reviewModel(store)).frame(width: 620, height: 470))),
            ("fix-word", AnyView(FixWordView(heard: "Kwilbo", corrected: "Qwilbo", onCancel: {}, onAdd: { _, _ in nil }))),
        ]
    }

    /// Settings in a scratch file: Hybrid learning, Claude's smallest model,
    /// and an example sentence.
    @MainActor
    private static func demoSettings(in dir: URL) -> SettingsStore {
        let store = SettingsStore(file: dir.appendingPathComponent("settings.json"), log: { _ in })
        var settings = Settings()
        settings.corrections.learning = .hybrid
        settings.corrections.provider = .claude
        settings.corrections.model = "claude-haiku-4-5"
        settings.dictionary.examples = [ExampleSentence.language: "Ask Qwilbo about the Zorblink sync."]
        store.write(settings)
        return store
    }

    @MainActor
    private static func reviewModel(_ store: SettingsStore) -> ReviewModel {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let local = LocalJudge(common: FixedCommonWords(words: []))
        func pair(_ word: String, _ heard: String, _ rules: [CorrectionRule], _ sources: [LearnedPair.Source], seen: Int,
                  status: LearnedPair.Status = .pending, kept: Int? = nil) -> LearnedPair {
            LearnedPair(word: word, heard: heard, rules: rules, status: status, sources: sources, seen: seen,
                        firstSeen: date, lastSeen: date, decided: status == .added ? date : nil,
                        target: status == .added ? .dictionary : nil, keptHeard: kept)
        }
        func review(_ pair: LearnedPair) -> CorrectionActions.Review {
            let change = WordChange(heard: WordDiff.words(pair.heard ?? "").map(\.text), corrected: WordDiff.words(pair.word).map(\.text))
            var verdict = local.judge(change, evidence: pair.evidence)
            verdict.rules = Set(pair.rules)
            return CorrectionActions.Review(pair: pair, change: change, verdict: verdict)
        }
        let model = ReviewModel(settings: store)
        model.pending = [
            review(pair("Zorblink", "zor blink", [.replace, .casing], [.wisprDictionary], seen: 12)),
            review(pair("QX7", "qx 7", [.casing], [.whisper, .wisprEdits], seen: 5, kept: 3)),
            review(pair("Qwilbo", "Kwilbo", [.replace, .casing], [.watched], seen: 2)),
        ]
        model.added = [
            pair("Zorbex Labs", "zorbex labs", [.casing, .prompt], [.wisprDictionary], seen: 8, status: .added),
            pair("Kwarn", "quarn", [.replace, .casing], [.fixWord], seen: 1, status: .added),
        ]
        model.promptTerms = ExampleSentence.terms(model.added)
        return model
    }

    // MARK: - Drawing

    @MainActor
    private static func render(_ view: AnyView, dark: Bool, to file: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // One turn of the run loop lets SwiftUI finish its first layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Twice the pixels, as on a Retina display, so the README stays sharp.
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw Failure.render(file.lastPathComponent) }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure.render(file.lastPathComponent) }
        try png.write(to: file)
        window.close()
    }
}
