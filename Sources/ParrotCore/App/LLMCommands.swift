import Foundation

/// Behind `parrot llm …` (ADR-006): the key, the model list, and a test.
public enum LLMCommands {
    /// Reads a key from standard input, without echo in a terminal, and
    /// saves it in the Keychain.
    public static func setKey(provider name: String) throws {
        let provider = try parse(name)
        let key: String
        if isatty(STDIN_FILENO) != 0 {
            guard let typed = getpass("\(provider.displayName) API key (not shown): ") else { throw SilentExit(1) }
            key = String(cString: typed)
        } else {
            key = readLine() ?? ""
        }
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("No key given; nothing saved.")
            throw SilentExit(1)
        }
        try CredentialStore().save(key, for: provider)
        print("Saved the \(provider.displayName) key in the Keychain.")
    }

    public static func removeKey(provider name: String) throws {
        let provider = try parse(name)
        try CredentialStore().remove(for: provider)
        print("Removed the \(provider.displayName) key.")
    }

    /// The models the provider in Settings offers.
    public static func models() throws {
        let client = try client()
        let result: Result<[String], Error> = CorrectionCommands.blocking {
            do { return .success(try await client.models()) } catch { return .failure(error) }
        }
        switch result {
        case .success(let ids): ids.forEach { print($0) }
        case .failure(let error):
            print("couldn't list models: \(error)")
            throw SilentExit(1)
        }
    }

    /// Sends made-up pairs to the judge in Settings and prints its verdicts.
    public static func test() throws {
        let settings = CorrectionSettings.saved()
        let client = try client()
        let items = [
            WordChange(heard: ["Kwilbo"], corrected: ["Qwilbo"]),
            WordChange(heard: ["Link"], corrected: ["Zorblink"]),
            WordChange(heard: ["weekend"], corrected: ["week"]),
        ].map { LLMJudge.Item(change: $0, evidence: CorrectionEvidence(seen: 3)) }
        print("Asking \(settings.provider.displayName) (\(settings.resolvedModel ?? "?")) about 3 made-up pairs…")
        let started = Date()
        let judge = LLMJudge(client: client, local: LocalJudge(), timeout: 30)
        let outcome = CorrectionCommands.blocking { await judge.judge(items) }
        if let failure = outcome.failures.first {
            print("failed: \(failure)")
            throw SilentExit(1)
        }
        for (item, verdict) in zip(items, outcome.verdicts) {
            let rules = verdict.rules.sorted().map(\.rawValue).joined(separator: ", ")
            print("  \(item.change.correctedText) ← \(item.change.heardText): \(rules.isEmpty ? "not learned" : rules)"
                  + (verdict.confidence.map { String(format: " (%.2f)", $0) } ?? ""))
        }
        print(String(format: "OK in %.1f s", Date().timeIntervalSince(started)))
    }

    private static func client() throws -> LLMClient {
        do {
            return try LLMClients.make(CorrectionSettings.saved())
        } catch {
            print("LLM judge: \(error). Choose a provider in Settings → Corrections, then `parrot llm set-key <provider>`.")
            throw SilentExit(1)
        }
    }

    private static func parse(_ name: String) throws -> LLMProvider {
        guard let provider = LLMProvider(rawValue: name.lowercased()), provider != .none else {
            print("unknown provider \(name); one of: \(LLMProvider.allCases.filter { $0 != .none }.map(\.rawValue).joined(separator: ", "))")
            throw SilentExit(64)
        }
        return provider
    }
}

extension CorrectionSettings {
    /// The saved settings, read directly, for commands without a
    /// `SettingsStore`.
    static func saved(in file: URL = Paths.settingsFile) -> CorrectionSettings {
        guard let data = try? Data(contentsOf: file), let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return CorrectionSettings()
        }
        return settings.corrections
    }
}
