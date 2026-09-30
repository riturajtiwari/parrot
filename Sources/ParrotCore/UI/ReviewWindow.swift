import AppKit
import SwiftUI

/// Review Corrections… (ADR-006): the pairs waiting for a decision, each
/// with its proposed rules, and the pairs added so far, each with Undo.
/// Reads and writes `corrections.json` and the dictionary through
/// `CorrectionActions`; holds no state of its own beyond the rule toggles.
@MainActor
final class ReviewWindow {
    private var window: NSWindow?
    private let model = ReviewModel()
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
    var onChange: (() -> Void)?

    private let actions = CorrectionActions()

    func reload() {
        do {
            pending = try actions.pending()
            added = try actions.added()
            for review in pending where choices[review.id] == nil {
                choices[review.id] = review.verdict.rules
            }
            error = nil
        } catch {
            self.error = "\(error)"
        }
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
        }
        .frame(minWidth: 560, minHeight: 420)
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
                Text("seen \(review.pair.seen)").font(.caption).foregroundStyle(.secondary)
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

    private func label(_ rule: CorrectionRule) -> String {
        switch rule {
        case .replace: return "Replace everywhere"
        case .casing: return "Spell it this way"
        case .prompt: return "Example sentence"
        }
    }
}
