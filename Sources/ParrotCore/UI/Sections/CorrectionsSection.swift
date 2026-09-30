import SwiftUI

/// Learned corrections and the LLM judge (fork, ADR-006): how Parrot learns,
/// which provider judges the pairs, and its key. The key goes to the
/// Keychain, never to `settings.json`.
struct CorrectionsSection: View {
    @ObservedObject var store: SettingsStore
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var models: [String] = []
    @State private var status: String?
    @State private var busy = false

    private let credentials = CredentialStore()

    private var settings: CorrectionSettings { store.current.corrections }
    private var provider: LLMProvider { settings.provider }

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

            PillRow("Judge") {
                PillMenu(title: provider.displayName) {
                    ForEach(LLMProvider.allCases, id: \.self) { choice in
                        Button(choice.displayName) {
                            store.update {
                                $0.corrections.provider = choice
                                $0.corrections.model = nil
                                $0.corrections.baseURL = nil
                            }
                            models = []
                            status = nil
                            refreshKey()
                        }
                    }
                }
            }

            if provider != .none {
                if provider == .custom {
                    field("Base URL", text: Binding(
                        get: { settings.baseURL ?? "" },
                        set: { value in store.update { $0.corrections.baseURL = value.isEmpty ? nil : value } }
                    ), placeholder: "https://…/v1")
                }

                HStack {
                    Text("Model")
                    Spacer()
                    if models.isEmpty {
                        TextField(provider.defaultModel ?? "model id", text: Binding(
                            get: { settings.model ?? "" },
                            set: { value in store.update { $0.corrections.model = value.isEmpty ? nil : value } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    } else {
                        PillMenu(title: settings.resolvedModel ?? "Choose a model") {
                            ForEach(models, id: \.self) { id in
                                Button(id) { store.update { $0.corrections.model = id } }
                            }
                        }
                    }
                    Button("Load Models", action: loadModels).buttonStyle(.pill).disabled(busy)
                }

                if provider.needsKey || provider == .custom {
                    HStack {
                        Text("API key")
                        Spacer()
                        if hasKey {
                            Text("Saved in the Keychain").foregroundStyle(.secondary)
                            Button("Remove", action: removeKey).buttonStyle(.pill)
                        } else {
                            SecureField("paste the key", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey).buttonStyle(.pill).disabled(keyDraft.isEmpty)
                        }
                    }
                }

                PillRow("Check") {
                    Button("Test Connection", action: test).buttonStyle(.pill).disabled(busy)
                }
                if let status { caption(status) }

                caption(provider.isRemote
                    ? "Sends each learned pair, such as “Kwilbo → Qwilbo”, to \(provider.displayName). Never a sentence, never audio."
                    : "The judge runs on this Mac. Nothing leaves it.")
            } else {
                caption("Only the local rules judge learned pairs. Nothing leaves this Mac.")
            }
        }
        .onAppear(perform: refreshKey)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).frame(width: 260)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func refreshKey() {
        hasKey = credentials.hasKey(for: provider)
        keyDraft = ""
    }

    private func saveKey() {
        do {
            try credentials.save(keyDraft, for: provider)
            status = "Key saved."
        } catch {
            status = "\(error)"
        }
        refreshKey()
    }

    private func removeKey() {
        do {
            try credentials.remove(for: provider)
            status = "Key removed."
        } catch {
            status = "\(error)"
        }
        refreshKey()
    }

    private func loadModels() {
        let settings = self.settings
        busy = true
        status = "Loading models…"
        Task {
            do {
                let ids = try await LLMClients.make(settings).models()
                await MainActor.run {
                    models = ids
                    status = ids.isEmpty ? "The provider lists no models." : nil
                    busy = false
                }
            } catch {
                await MainActor.run {
                    status = "Couldn't load models: \(error)"
                    busy = false
                }
            }
        }
    }

    /// Three made-up pairs, the same as `parrot llm test`.
    private func test() {
        let settings = self.settings
        busy = true
        status = "Asking \(settings.provider.displayName)…"
        Task {
            let started = Date()
            let message: String
            do {
                let judge = LLMJudge(client: try LLMClients.make(settings), local: LocalJudge(), timeout: 30)
                let items = [
                    WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"]),
                    WordChange(heard: ["weekend"], corrected: ["week"]),
                ].map { LLMJudge.Item(change: $0, evidence: CorrectionEvidence(seen: 3)) }
                let outcome = await judge.judge(items)
                if let failure = outcome.failures.first {
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
        case .review: return "Parrot collects corrections. Nothing changes until you accept one in Review Corrections."
        case .hybrid: return "Parrot adds clear fixes of rare words at once, with Undo, and queues the rest. It starts when its precision on your reviews reaches 95%."
        }
    }
}
