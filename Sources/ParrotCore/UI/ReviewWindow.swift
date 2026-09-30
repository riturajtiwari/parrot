import AppKit
import SwiftUI

/// Review Corrections… (ADR-006): the pairs waiting for a decision, each
/// with its proposed rules, and the pairs added so far, each with Undo.
/// Reads and writes `corrections.json` and the dictionary through
/// `CorrectionActions`; holds no state of its own beyond the rule toggles.
@MainActor
final class ReviewWindow {
    private var window: NSWindow?
    private let model: ReviewModel

    init(settings: SettingsStore? = nil) {
        model = ReviewModel(settings: settings)
    }
    /// Called after every change, so the menu bar can update its count.
    var onChange: (() -> Void)? {
        get { model.onChange }
        set { model.onChange = newValue }
    }

    func show() {
        model.reload()
        let window = self.window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Review Corrections"
        window.contentView = NSHostingView(rootView: ReviewView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

@MainActor
final class ReviewModel: ObservableObject {
    @Published var pending: [CorrectionActions.Review] = []
    @Published var added: [LearnedPair] = []
    @Published var choices: [String: Set<CorrectionRule>] = [:]
    @Published var error: String?
    /// The example sentence as the user edits it, and the terms of accepted
    /// `prompt` rules that it should hold.
    @Published var sentence = ""
    @Published var promptTerms: [String] = []
    var onChange: (() -> Void)?

    private let actions = CorrectionActions()
    private let settings: SettingsStore?

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        sentence = savedSentence
    }

    func reload() {
        do {
            let editing = sentence != savedSentence
            pending = try actions.pending()
            added = try actions.added()
            promptTerms = ExampleSentence.terms(added)
            for review in pending where choices[review.id] == nil {
                choices[review.id] = review.verdict.rules
            }
            if !editing { sentence = savedSentence }
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Whether the window can show and save the example sentence.
    var hasSettings: Bool { settings != nil }

    var savedSentence: String {
        settings?.current.dictionary.examples[ExampleSentence.language] ?? ""
    }

    var missingTerms: [String] {
        ExampleSentence.missing(promptTerms, in: sentence)
    }

    func saveSentence() {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        settings?.update { $0.dictionary.examples[ExampleSentence.language] = text.isEmpty ? nil : text }
        sentence = savedSentence
    }

    func rules(_ review: CorrectionActions.Review) -> Set<CorrectionRule> {
        choices[review.id] ?? review.verdict.rules
    }

    func toggle(_ rule: CorrectionRule, _ review: CorrectionActions.Review) {
        var rules = self.rules(review)
        if rules.contains(rule) { rules.remove(rule) } else { rules.insert(rule) }
        choices[review.id] = rules
    }

    func accept(_ review: CorrectionActions.Review) {
        if review.pair.status == .suspect {
            run { try self.actions.keep(review.pair) }
            return
        }
        run { try self.actions.accept(review.change, rules: self.rules(review), source: review.pair.sources.first ?? .wisprEdits, seen: review.pair.seen) }
    }

    /// No to a pending pair; for a suspect one, removes its rows too.
    func reject(_ review: CorrectionActions.Review) {
        if review.pair.status == .suspect {
            run { try self.actions.undo(review.pair) }
            return
        }
        run { try self.actions.reject(word: review.pair.word, heard: review.pair.heard) }
    }

    func undo(_ pair: LearnedPair) {
        run { try self.actions.undo(pair) }
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            reload()
            onChange?()
        } catch {
            self.error = "\(error)"
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.error {
                Text(error).foregroundStyle(.red).padding(12)
            }
            List {
                Section("To review (\(model.pending.count))") {
                    if model.pending.isEmpty {
                        Text("Nothing waits for review.").foregroundStyle(.secondary)
                    }
                    ForEach(model.pending) { review in
                        PendingRow(review: review, model: model)
                    }
                }
                Section("Added (\(model.added.count))") {
                    ForEach(model.added, id: \.key) { pair in
                        HStack {
                            Text(pair.word).bold()
                            if let heard = pair.heard { Text("← \(heard)").foregroundStyle(.secondary) }
                            Spacer()
                            Text(pair.rules.map(\.rawValue).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Button("Undo") { model.undo(pair) }
                        }
                    }
                }
            }
            if model.hasSettings {
                Divider()
                ExampleSentenceEditor(model: model)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// The example sentence under the lists: Whisper reads it before each
/// dictation, so it biases the model toward the terms in it.
private struct ExampleSentenceEditor: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        let count = ExampleSentence.wordCount(model.sentence)
        VStack(alignment: .leading, spacing: 6) {
            Text("Example sentence").font(.headline)
            Text("Whisper reads this sentence before each dictation, so it writes its words your way. Use the terms that need it, the way you say them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("A short sentence with your terms", text: $model.sentence)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveSentence() }
                Button("Save") { model.saveSentence() }
                    .disabled(model.sentence == model.savedSentence)
            }
            if !model.missingTerms.isEmpty {
                Text("Not in the sentence yet: \(model.missingTerms.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if count > ExampleSentence.suggestedMaxWords {
                Text("\(count) words. Each word adds about 4 ms to every dictation, so keep it to \(ExampleSentence.suggestedMaxWords) or fewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

private struct PendingRow: View {
    let review: CorrectionActions.Review
    @ObservedObject var model: ReviewModel

    var body: some View {
        let rules = model.rules(review)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(review.pair.word).bold()
                if let heard = review.pair.heard { Text("← \(heard)").foregroundStyle(.secondary) }
                Text("seen \(review.pair.seen) · \(Self.origin(review.pair.sources))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reject") { model.reject(review) }
                Button("Accept") { model.accept(review) }.disabled(rules.isEmpty)
            }
            HStack(spacing: 14) {
                ForEach(CorrectionRule.allCases, id: \.self) { rule in
                    Toggle(label(rule), isOn: Binding(get: { rules.contains(rule) }, set: { _ in model.toggle(rule, review) }))
                        .toggleStyle(.checkbox)
                        .disabled(rule == .replace && review.change.heard.isEmpty)
                }
            }
            ForEach(CorrectionActions.warnings(review.change, rules: rules), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if !review.verdict.reasons.isEmpty {
                Text(review.verdict.reasons.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Where the pair came from, in words.
    static func origin(_ sources: [LearnedPair.Source]) -> String {
        sources.map { source in
            switch source {
            case .wisprDictionary: return "Wispr dictionary"
            case .wisprEdits: return "Wispr edits"
            case .whisper: return "Parrot's model"
            case .watched: return "your edit"
            case .fixWord: return "Fix Word"
            }
        }.joined(separator: ", ")
    }

    private func label(_ rule: CorrectionRule) -> String {
        switch rule {
        case .replace: return "Replace everywhere"
        case .casing: return "Spell it this way"
        case .prompt: return "Example sentence"
        }
    }
}
