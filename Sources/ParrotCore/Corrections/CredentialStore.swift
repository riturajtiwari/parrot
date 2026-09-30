import Foundation
import Security

/// API keys for the LLM judge, in the login Keychain (ADR-006): never in
/// `settings.json`, which may live in a dotfiles repository.
///
/// One generic password per provider, under the service
/// `<bundle id>.llm`. The Keychain lets the process that saved a key read it
/// without a prompt, so the app saves the key from its settings screen, and
/// the `parrot` command reads it as the same executable.
struct CredentialStore: Sendable {
    let service: String

    init(service: String = AppBundle.identifier + ".llm") {
        self.service = service
    }

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)

        var description: String {
            switch self {
            case .keychain(let status):
                return "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            }
        }
    }

    func key(for provider: LLMProvider) throws -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    func hasKey(for provider: LLMProvider) -> Bool {
        var query = base(provider)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func save(_ key: String, for provider: LLMProvider) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = SecItemUpdate(base(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.keychain(update) }
        var item = base(provider)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Parrot \(provider.displayName) API key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func remove(for provider: LLMProvider) throws {
        let status = SecItemDelete(base(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private func base(_ provider: LLMProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
