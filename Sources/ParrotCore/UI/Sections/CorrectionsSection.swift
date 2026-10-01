import SwiftUI

/// Learned corrections and the LLM judge (fork, ADR-006): how Parrot learns,
/// which provider judges the pairs, the Wispr Flow import, and the way to
/// Review Corrections. Keys go to the Keychain, never to `settings.json`.
struct CorrectionsSection: View {
    @ObservedObject var store: SettingsStore
    /// Opens Review Corrections.
    var openReview: () -> Void = {}

    /// The provider whose Connect window is open. With a saved key, the
    /// window goes straight to the models.
    @State private var connecting: LLMProvider?
    @State private var hasKey = false
    @State private var status: String?
    @State private var busy = false
    @State private var importing = false
    @State private var importStatus: String?
    @State private var pendingCount = 0

    private let credentials = CredentialStore()

    private var settings: CorrectionSettings { store.current.corrections }
    private var provider: LLMProvider { settings.provider }

    /// A provider is set and has what it needs to answer.
    private var isConnected: Bool {
        switch provider {
        case .none: return false
        case .custom: return settings.resolvedBaseURL != nil
        default: return !provider.needsKey || hasKey
        }
    }

    var body: some View {
        SettingsGroup("Corrections") {
            PillRow("Learning") {
                PillMenu(title: Self.title(settings.learning)) {
                    ForEach(CorrectionSettings.Learning.allCases, id: \.self) { mode in
                        Button(Self.title(mode)) { store.update { $0.corrections.learning = mode } }
                    }
                }
            }
            caption(Self.explanation(settings.learning))
            if settings.learning == .hybrid {
                caption(HybridGate.status((try? LearnedStore().load().pairs) ?? []).summary)
            }
            if settings.learning != .off {
                PillRow("Notices") {
                    Toggle("Show what Parrot learns", isOn: Binding(
                        get: { settings.showNotices },
                        set: { on in store.update { $0.corrections.showNotices = on } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                caption("A notice above the dictation pill says what Parrot made of each edit, with Add, Not this or Undo.")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Judge")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(LLMProvider.connectable) { choice in
                        ProviderTile(provider: choice, selected: isConnected && choice == provider) {
                            connecting = choice
                        }
                    }
                }
            }
            judge

            if WisprImportRun.isAvailable() {
                PillRow("Wispr Flow") {
                    Button(importing ? "Importing…" : "Import", action: importWispr)
                        .buttonStyle(.pill)
                        .disabled(importing)
                }
                caption(importStatus ?? (isConnected
                    ? "Reads the words Wispr Flow learned and the edits you made there. Wispr's files stay as they are. \(provider.shortName) checks each pair, and the proposals go to Review Corrections."
                    : "Reads the words Wispr Flow learned and the edits you made there. Wispr's files stay as they are. The proposals go to Review Corrections."))
            }
            PillRow("Review") {
                Button(pendingCount > 0 ? "Review \(pendingCount) Corrections…" : "Review Corrections…", action: openReview)
                    .buttonStyle(.pill)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: provider) { refresh() }
        .sheet(item: $connecting, onDismiss: refresh) { choice in
            ConnectSheet(provider: choice, store: store) { connecting = nil }
        }
    }

    // MARK: - Judge

    @ViewBuilder private var judge: some View {
        if provider == .none {
            caption("Only the local rules judge learned pairs, and nothing leaves this Mac. Click a provider to connect it.")
        } else if !isConnected {
            caption("\(provider.shortName) has no key. Click its tile to connect it.")
        } else {
            PillRow("Model") {
                HStack {
                    Text(settings.resolvedModel ?? "none").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { connecting = provider }
                    .buttonStyle(.pill)
                    .disabled(busy)
                }
            }
            PillRow("Check") {
                HStack {
                    Button("Test Connection", action: test).buttonStyle(.pill).disabled(busy)
                    Button("Disconnect", action: disconnect).buttonStyle(.pill).disabled(busy)
                }
            }
            if let status { caption(status) }
            caption(provider.isRemote
                ? "Sends each learned pair, such as “Kwilbo → Qwilbo”, to \(provider.displayName). Never a sentence, never audio."
                : "The judge runs on this Mac. Nothing leaves it.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() {
        hasKey = provider == .none ? false : credentials.hasKey(for: provider)
        pendingCount = (try? CorrectionActions().pendingCount()) ?? 0
    }

    private func disconnect() {
        let old = provider
        if old != .ollama, old != .lmstudio { try? credentials.remove(for: old) }
        store.update {
            $0.corrections.provider = .none
            $0.corrections.model = nil
            $0.corrections.baseURL = nil
        }
        if let page = old.keysPage {
            status = "Disconnected, and the key is out of the Keychain. It still works at \(old.shortName) until you delete it at \(page.host ?? page.absoluteString)."
        } else {
            status = "Disconnected."
        }
        refresh()
    }

    /// Two made-up pairs, the same as `parrot llm test`.
    private func test() {
        let settings = self.settings
        busy = true
        status = "Asking \(settings.provider.displayName)…"
        Task {
            let started = Date()
            let message: String
            do {
                let client = try LLMClients.make(settings)
                if let failure = await ProviderConnect.test(client) {
                    message = "Failed: \(failure)"
                } else {
                    message = String(format: "Works: answered in %.1f s.", Date().timeIntervalSince(started))
                }
            } catch {
                message = "\(error)"
            }
            await MainActor.run {
                status = message
                busy = false
            }
        }
    }

    // MARK: - Wispr Flow

    private func importWispr() {
        var settings = self.settings
        // A provider without its key can't judge; the local rules still do.
        if !isConnected { settings.provider = .none }
        importing = true
        importStatus = "Reading Wispr Flow…"
        Task {
            do {
                let report = try await WisprImportRun().run(settings: settings, progress: { text in
                    Task { @MainActor in importStatus = text }
                })
                importStatus = Self.summary(report)
                importing = false
                refresh()
                if report.proposed > 0 { openReview() }
            } catch {
                importStatus = "Couldn't import: \(error)"
                importing = false
            }
        }
    }

    static func summary(_ report: WisprImportRun.Report) -> String {
        var parts = [report.proposed == 1
            ? "Added 1 proposal to Review Corrections."
            : "Added \(report.proposed) proposals to Review Corrections."]
        if let judge = report.judge { parts.append("\(judge.shortName) checked them.") }
        if report.declined > 0 { parts.append("\(report.declined) pairs teach nothing, such as rewording or common words.") }
        if report.decided > 0 { parts.append("\(report.decided) you decided before.") }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) judge request(s) failed, so those pairs kept the local rules: \(report.failures[0]).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Text

    private static func title(_ mode: CorrectionSettings.Learning) -> String {
        switch mode {
        case .off: return "Off"
        case .review: return "Review"
        case .hybrid: return "Hybrid"
        }
    }

    private static func explanation(_ mode: CorrectionSettings.Learning) -> String {
        switch mode {
        case .off: return "Parrot learns nothing from your corrections."
        case .review: return "Parrot asks before it learns: Add or Not this. Nothing changes until you add a word."
        case .hybrid: return "Parrot asks first. When its proposals match 95% of your choices over 20 of them, it adds clear fixes of rare words at once, with Undo."
        }
    }
}
