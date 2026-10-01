import Foundation

/// A service that can judge learned pairs (ADR-006). Claude has its own
/// adapter; every other provider speaks the OpenAI chat-completions format,
/// which Gemini, OpenRouter, Ollama and LM Studio also serve.
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case none, claude, openai, gemini, openrouter, ollama, lmstudio, custom

    var displayName: String {
        switch self {
        case .none: return "None (local rules only)"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama (on this Mac)"
        case .lmstudio: return "LM Studio (on this Mac)"
        case .custom: return "Other OpenAI-compatible"
        }
    }

    /// Where requests go, unless the settings name another base URL.
    var baseURL: URL? {
        switch self {
        case .none, .custom: return nil
        case .claude: return URL(string: "https://api.anthropic.com/v1")
        case .openai: return URL(string: "https://api.openai.com/v1")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1")
        case .ollama: return URL(string: "http://localhost:11434/v1")
        case .lmstudio: return URL(string: "http://localhost:1234/v1")
        }
    }

    /// The model used when the settings name none. Only Claude has one; for
    /// the others, "Load models" asks the provider for its list. The judge
    /// only sorts word pairs, so the smallest, fastest model is enough.
    var defaultModel: String? {
        self == .claude ? "claude-haiku-4-5" : nil
    }

    /// A local server needs no key.
    var needsKey: Bool {
        ![.none, .ollama, .lmstudio, .custom].contains(self)
    }

    /// The text leaves this Mac.
    var isRemote: Bool {
        ![.none, .ollama, .lmstudio].contains(self)
    }
}

/// Learned-corrections preferences (ADR-006): the `corrections` field of
/// `settings.json`. The API key is never here: this file may live in a
/// dotfiles repository, so the key is in the Keychain (`CredentialStore`).
///
/// Give each new field a default and decode it with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct CorrectionSettings: Codable, Equatable, Sendable {
    enum Learning: String, Codable, CaseIterable, Sendable {
        /// Collect nothing.
        case off
        /// Collect candidates; change nothing until the user accepts one.
        case review
        /// Add clear fixes of rare words to the overlay at once, with Undo;
        /// queue the rest. Waits for the precision gate (ADR-006).
        case hybrid
    }

    var learning: Learning = .review
    var provider: LLMProvider = .none
    /// Nil: the provider's default.
    var model: String?
    /// Nil: the provider's base URL. Required for `custom`.
    var baseURL: String?
    /// Send a few words around each pair. Off: the pair only.
    var sendContext = false
    /// At most this many pairs from one dictation go to the judge.
    var maxPerDictation = 4
    /// How long the edit watcher follows a field after a paste.
    var watchSeconds = 60
    /// The apps whose fields the edit watcher follows, by bundle id. Apps
    /// whose text fields `parrot-bench ax-probe` shows as readable. Never
    /// terminals, code editors or password managers.
    var watchedApps = CorrectionSettings.defaultWatchedApps
    /// The learning notice above the recording pill says what Parrot made
    /// of each edit.
    var showNotices = true

    static let defaultWatchedApps = [
        "com.apple.TextEdit", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS",
        "com.apple.Safari", "com.google.Chrome", "com.tinyspeck.slackmacgap", "com.microsoft.Outlook",
        "com.anthropic.claudefordesktop",
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        learning = (try? c.decodeIfPresent(Learning.self, forKey: .learning)) ?? .review
        provider = (try? c.decodeIfPresent(LLMProvider.self, forKey: .provider)) ?? LLMProvider.none
        model = try c.decodeIfPresent(String.self, forKey: .model)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        sendContext = try c.decodeIfPresent(Bool.self, forKey: .sendContext) ?? false
        maxPerDictation = try c.decodeIfPresent(Int.self, forKey: .maxPerDictation) ?? 4
        watchSeconds = try c.decodeIfPresent(Int.self, forKey: .watchSeconds) ?? 60
        watchedApps = try c.decodeIfPresent([String].self, forKey: .watchedApps) ?? Self.defaultWatchedApps
        showNotices = try c.decodeIfPresent(Bool.self, forKey: .showNotices) ?? true
    }

    /// The model to ask, or nil when there is none to ask.
    var resolvedModel: String? {
        let named = model?.trimmingCharacters(in: .whitespaces)
        return (named?.isEmpty == false ? named : nil) ?? provider.defaultModel
    }

    /// The base URL to use, or nil when there is none.
    var resolvedBaseURL: URL? {
        if let text = baseURL?.trimmingCharacters(in: .whitespaces), !text.isEmpty, let url = URL(string: text) { return url }
        return provider.baseURL
    }
}
