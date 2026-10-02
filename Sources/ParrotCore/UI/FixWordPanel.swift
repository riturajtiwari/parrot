import AppKit
import SwiftUI

/// Fix Word… (ADR-006, upstream #54): what the model wrote, what it should
/// be, and which rules to add. Opened from the menu bar or the "Fix Word in
/// Parrot" service with the selected text. The local rules propose the
/// rules; the user decides, with a warning when a rule would change ordinary
/// text.
@MainActor
final class FixWordPanel {
    private var panel: NSPanel?
    /// Called with the pair and rules to add. Returns an error message, or
    /// nil when the rows were written.
    var onAdd: ((WordChange, Set<CorrectionRule>) -> String?)?

    func show(heard: String) {
        panel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Fix Word"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FixWordView(
            heard: heard,
            onCancel: { [weak panel] in panel?.close() },
            onAdd: { [weak self, weak panel] change, rules in
                guard let self else { return "Parrot isn't ready" }
                let error = self.onAdd?(change, rules)
                if error == nil { panel?.close() }
                return error
            }
        ))
        panel.center()
        self.panel = panel
        // An accessory app is never active on its own; without this the
        // panel opens behind the app the user is in.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct FixWordView: View {
    @State var heard: String
    @State private var corrected = ""
    @State private var rules: Set<CorrectionRule> = []
    @State private var reasons: [String] = []
    @State private var error: String?
    let onCancel: () -> Void
    let onAdd: (WordChange, Set<CorrectionRule>) -> String?

    /// `corrected` fills the second field, with the rules the local rules
    /// propose for it, as the README screenshots show.
    init(heard: String, corrected: String = "", onCancel: @escaping () -> Void, onAdd: @escaping (WordChange, Set<CorrectionRule>) -> String?) {
        _heard = State(initialValue: heard)
        _corrected = State(initialValue: corrected)
        self.onCancel = onCancel
        self.onAdd = onAdd
        if !corrected.isEmpty {
            let change = WordChange(heard: WordDiff.words(heard).map(\.text), corrected: WordDiff.words(corrected).map(\.text))
            let verdict = LocalJudge().judge(change, evidence: CorrectionEvidence(manual: true))
            _rules = State(initialValue: verdict.rules)
            _reasons = State(initialValue: verdict.reasons)
        }
    }

    private let judge = LocalJudge()

    private var change: WordChange {
        WordChange(heard: WordDiff.words(heard).map(\.text), corrected: WordDiff.words(corrected).map(\.text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Parrot wrote").foregroundStyle(.secondary)
                    TextField("the misheard word", text: $heard)
                }
                GridRow {
                    Text("Should be").foregroundStyle(.secondary)
                    TextField("your spelling", text: $corrected)
                        .onSubmit(add)
                }
            }
            .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: binding(.replace)) {
                    Text(change.heard.isEmpty ? "Replace the misheard word everywhere" : "Replace “\(change.heardText)” everywhere")
                }
                .disabled(change.heard.isEmpty)
                Toggle("Always spell it this way", isOn: binding(.casing))
                Toggle("Suggest it for the example sentence", isOn: binding(.prompt))
            }
            .toggleStyle(.checkbox)

            ForEach(CorrectionActions.warnings(change, rules: rules), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            if !reasons.isEmpty, rules.isEmpty {
                Text("Parrot proposes nothing: \(reasons.joined(separator: "; ")).").font(.callout).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(change.corrected.isEmpty || rules.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: corrected) { propose() }
        .onChange(of: heard) { propose() }
        .onAppear { if corrected.isEmpty { corrected = heard } }
    }

    private func binding(_ rule: CorrectionRule) -> Binding<Bool> {
        Binding(get: { rules.contains(rule) }, set: { on in
            if on { rules.insert(rule) } else { rules.remove(rule) }
        })
    }

    /// The local rules' proposal for the pair as typed.
    private func propose() {
        error = nil
        guard !change.corrected.isEmpty, change.correctedText != change.heardText else {
            rules = []
            reasons = []
            return
        }
        let verdict = judge.judge(change, evidence: CorrectionEvidence(manual: true))
        rules = verdict.rules
        reasons = verdict.reasons
    }

    private func add() {
        guard !change.corrected.isEmpty, !rules.isEmpty else { return }
        error = onAdd(change, rules)
    }
}
