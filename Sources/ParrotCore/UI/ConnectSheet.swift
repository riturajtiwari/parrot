import AppKit
import SwiftUI

extension LLMProvider: Identifiable {
    var id: String { rawValue }
}

/// One provider in the Judge grid of Settings → Corrections: its logo and
/// name, with a check mark when Parrot is connected to it.
struct ProviderTile: View {
    let provider: LLMProvider
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ProviderLogo(provider: provider, size: 24)
                Text(provider.shortName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.12 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(selected ? "Connected to \(provider.displayName)" : "Connect \(provider.displayName)")
        .accessibilityLabel(provider.displayName)
    }
}

/// The Connect window for one provider (ADR-006). It gets a key, or finds a
/// server on this Mac, picks a model, and saves them: the key in the
/// Keychain, the provider and the model in `settings.json`. It reads the
/// clipboard only while it is open, and takes only text in the shape of
/// that provider's key.
@MainActor
final class ConnectModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        /// Waiting for the user: a key on the clipboard, or the browser sign-in.
        case waiting
        case working(String)
        case connected(String)
        case failed(String)
    }

    let provider: LLMProvider
    @Published var phase: Phase = .ready
    @Published var pastedKey = ""
    @Published var baseURL = ""
    @Published private(set) var clearedClipboard = false
    @Published private(set) var hasSavedKey: Bool

    private let store: SettingsStore
    private let credentials: CredentialStore
    /// The clipboard's change count already looked at; -1 looks at once.
    private var seenChange = -1
    private var signIn: LoopbackCallback?
    private var task: Task<Void, Never>?

    init(provider: LLMProvider, store: SettingsStore, credentials: CredentialStore = CredentialStore()) {
        self.provider = provider
        self.store = store
        self.credentials = credentials
        hasSavedKey = provider.connectMethod != .manual && credentials.hasKey(for: provider)
        if provider == .custom, store.current.corrections.provider == .custom {
            baseURL = store.current.corrections.baseURL ?? ""
        }
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// When the window opens: a key copied just before counts, and a local
    /// server is looked for at once.
    func start() {
        switch provider.connectMethod {
        case .keyPage: pollClipboard()
        case .localServer: findLocalServer()
        case .openRouterSignIn, .manual: break
        }
    }

    func cancel() {
        task?.cancel()
        signIn?.stop()
        signIn = nil
    }

    // MARK: - A key from the provider's page

    func openKeyPage() {
        guard case .keyPage(let page) = provider.connectMethod else { return }
        NSWorkspace.shared.open(page)
        if !isBusy { phase = .waiting }
    }

    /// Looks at the clipboard; the window calls it twice a second.
    func pollClipboard() {
        guard case .keyPage = provider.connectMethod, !isBusy, !isConnected else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != seenChange else { return }
        seenChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), provider.looksLikeKey(text) else { return }
        connect(key: text, fromClipboard: true)
    }

    func connectPasted() {
        connect(key: pastedKey, fromClipboard: false)
    }

    /// Uses the key already in the Keychain for this provider.
    func useSavedKey() {
        guard let key = try? credentials.key(for: provider), !key.isEmpty else {
            hasSavedKey = false
            return
        }
        connect(key: key, fromClipboard: false, save: false)
    }

    private func connect(key raw: String, fromClipboard: Bool, save: Bool = true) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let provider = self.provider
        phase = .working("Checking the key with \(provider.shortName)…")
        task = Task {
            do {
                let ids = try await ProviderConnect.check(key, for: provider)
                if save { try credentials.save(key, for: provider) }
                if fromClipboard, NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == key {
                    NSPasteboard.general.clearContents()
                    clearedClipboard = true
                }
                finish(model: ProviderConnect.suggestModel(for: provider, from: ids))
            } catch {
                phase = .failed(Self.message(error, provider: provider))
            }
        }
    }

    // MARK: - OpenRouter sign-in

    func startSignIn() {
        let verifier = PKCE.verifier()
        phase = .waiting
        task = Task {
            do {
                let callback = try LoopbackCallback()
                signIn = callback
                let address = try await callback.start()
                NSWorkspace.shared.open(OpenRouterSignIn.authorizeURL(callback: address, challenge: PKCE.challenge(for: verifier)))
                let query = try await callback.wait(timeout: 300)
                signIn = nil
                guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    throw LLMError.malformed("OpenRouter sent no code")
                }
                phase = .working("Getting the key from OpenRouter…")
                let key = try await OpenRouterSignIn.key(code: code, verifier: verifier)
                try credentials.save(key, for: .openrouter)
                phase = .working("Choosing a model…")
                let ids = (try? await ProviderConnect.check(key, for: .openrouter)) ?? []
                finish(model: ProviderConnect.suggestModel(for: .openrouter, from: ids))
            } catch LoopbackCallback.Failure.cancelled {
                phase = .ready
            } catch {
                phase = .failed(Self.message(error, provider: .openrouter))
            }
        }
    }

    // MARK: - A server on this Mac

    func findLocalServer() {
        let provider = self.provider
        phase = .working("Looking for \(provider.shortName) on this Mac…")
        task = Task {
            guard let ids = await ProviderConnect.localModels(provider) else {
                phase = .failed("\(provider.shortName) isn't running. Start it, then click Try Again.")
                return
            }
            guard let model = ProviderConnect.suggestModel(for: provider, from: ids) else {
                phase = .failed(provider == .ollama
                    ? "Ollama has no models. Get one, for example with `ollama pull llama3.2`, then click Try Again."
                    : "LM Studio has no model loaded. Load one, then click Try Again.")
                return
            }
            finish(model: model)
        }
    }

    // MARK: - Any other OpenAI-compatible server

    func connectCustom() {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: text), base.scheme == "http" || base.scheme == "https", base.host != nil else {
            phase = .failed("Type the server's base URL, such as https://example.com/v1.")
            return
        }
        let key = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .working("Asking the server for its models…")
        task = Task {
            do {
                let ids = try await ProviderConnect.check(key, for: .custom, baseURL: base)
                if key.isEmpty { try? credentials.remove(for: .custom) } else { try credentials.save(key, for: .custom) }
                finish(model: ProviderConnect.suggestModel(for: .custom, from: ids), baseURL: text)
            } catch {
                phase = .failed(Self.message(error, provider: .custom))
            }
        }
    }

    // MARK: -

    private func finish(model: String?, baseURL: String? = nil) {
        let provider = self.provider
        store.update {
            $0.corrections.provider = provider
            $0.corrections.model = model
            $0.corrections.baseURL = baseURL
        }
        hasSavedKey = provider.connectMethod != .manual && credentials.hasKey(for: provider)
        // The provider only: never the key.
        Log.info("corrections: connected the judge to \(provider.rawValue)")
        phase = .connected("Connected to \(provider.shortName)" + (model.map { ", with the model \($0)" } ?? "") + ".")
    }

    static func message(_ error: Error, provider: LLMProvider) -> String {
        switch error {
        case LLMError.http(let status, _) where status == 401 || status == 403:
            return "\(provider.shortName) did not accept the key. Copy it again, or make a new one."
        case LLMError.http(400, let message) where message.localizedCaseInsensitiveContains("key"):
            return "\(provider.shortName) did not accept the key. Copy it again, or make a new one."
        case LLMError.network:
            return "Couldn't reach \(provider.shortName). Check the network, then try again."
        case let failure as LoopbackCallback.Failure:
            return "Couldn't finish the sign-in: \(failure)."
        default:
            return "Couldn't connect: \(error)."
        }
    }
}

struct ConnectSheet: View {
    @StateObject private var model: ConnectModel
    let onClose: () -> Void
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(provider: LLMProvider, store: SettingsStore, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ConnectModel(provider: provider, store: store))
        self.onClose = onClose
    }

    private var provider: LLMProvider { model.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProviderLogo(provider: provider, size: 30)
                Text("Connect \(provider.shortName)").font(.title3.weight(.semibold))
            }
            switch provider.connectMethod {
            case .keyPage: keyPage
            case .openRouterSignIn: openRouter
            case .localServer(let download): localServer(download)
            case .manual: manual
            }
            status
            HStack {
                Spacer()
                if model.isConnected {
                    Button("Done") { close() }
                        .buttonStyle(.primaryPill)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { close() }
                        .buttonStyle(.pill)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { model.start() }
        .onDisappear { model.cancel() }
        .onReceive(clock) { _ in model.pollClipboard() }
    }

    private func close() {
        model.cancel()
        onClose()
    }

    // MARK: - Methods

    @ViewBuilder private var keyPage: some View {
        if model.hasSavedKey, !model.isConnected {
            savedKeyRow
        }
        step(1, "Open the \(provider.keyPageName), sign in, and make a key.") {
            Button("Open \(provider.keyPageName)") { model.openKeyPage() }
                .buttonStyle(.primaryPill)
                .disabled(model.isBusy || model.isConnected)
        }
        step(2, "Copy the key. Parrot takes it from the clipboard, checks it, and saves it in the Keychain.") {
            HStack {
                SecureField("or paste the key here", text: $model.pastedKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connectPasted() }
                Button("Connect") { model.connectPasted() }
                    .buttonStyle(.pill)
                    .disabled(model.pastedKey.isEmpty || model.isBusy || model.isConnected)
            }
        }
        caption("Parrot reads the clipboard only while this window is open, and takes only text in the shape of a \(provider.shortName) key.")
    }

    @ViewBuilder private var openRouter: some View {
        if model.hasSavedKey, !model.isConnected {
            savedKeyRow
        }
        Text("Sign in to OpenRouter in your browser. OpenRouter then gives Parrot a key of its own. You can see it and delete it on openrouter.ai.")
            .fixedSize(horizontal: false, vertical: true)
        Button("Sign In with OpenRouter") { model.startSignIn() }
            .buttonStyle(.primaryPill)
            .disabled(model.phase == .waiting || model.isBusy || model.isConnected)
    }

    @ViewBuilder private func localServer(_ download: URL) -> some View {
        Text("\(provider.shortName) runs models on this Mac, so nothing leaves it.")
            .fixedSize(horizontal: false, vertical: true)
        if case .failed = model.phase {
            HStack {
                Button("Try Again") { model.findLocalServer() }.buttonStyle(.primaryPill)
                Button("Get \(provider.shortName)") { NSWorkspace.shared.open(download) }.buttonStyle(.pill)
            }
        }
    }

    @ViewBuilder private var manual: some View {
        Text("Any server with an OpenAI-compatible API.")
        labeled("Base URL") {
            TextField("https://example.com/v1", text: $model.baseURL).textFieldStyle(.roundedBorder)
        }
        labeled("API key") {
            SecureField("if the server needs one", text: $model.pastedKey).textFieldStyle(.roundedBorder)
        }
        HStack {
            Spacer()
            Button("Connect") { model.connectCustom() }
                .buttonStyle(.primaryPill)
                .disabled(model.baseURL.isEmpty || model.isBusy || model.isConnected)
        }
    }

    // MARK: - Parts

    private var savedKeyRow: some View {
        HStack {
            Text("A key is saved in the Keychain.")
            Spacer()
            Button("Use It") { model.useSavedKey() }
                .buttonStyle(.pill)
                .disabled(model.isBusy)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .ready:
            EmptyView()
        case .waiting:
            progress(provider.connectMethod == .openRouterSignIn
                ? "Waiting for the sign-in in your browser…"
                : "Waiting for a key on the clipboard…")
        case .working(let text):
            progress(text)
        case .connected(let text):
            VStack(alignment: .leading, spacing: 4) {
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if model.clearedClipboard {
                    caption("Parrot removed the key from the clipboard.")
                }
            }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func step<Content: View>(_ number: Int, _ text: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 8) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
