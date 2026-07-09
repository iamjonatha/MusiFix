import Foundation
import Security

/// Persistenza della configurazione LLM: provider/modello/endpoint in `UserDefaults`,
/// chiave API nel **Keychain** (per provider). Nessun segreto finisce in chiaro.
public enum LLMConfigStore {
    private static let providerKey = "llm.provider"
    private static let modelKey = "llm.model"
    private static let endpointKey = "llm.endpoint"
    private static let keychainService = "MusiFix.LLM"

    private static var defaults: UserDefaults { .standard }

    // ── Config non segreta ────────────────────────────────────────────────────

    public static var provider: LLMProvider {
        get { LLMProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .anthropic }
        set { defaults.set(newValue.rawValue, forKey: providerKey) }
    }

    /// Modello configurato per il provider corrente (fallback: default del provider).
    public static var model: String {
        get {
            let v = defaults.string(forKey: modelKey) ?? ""
            return v.isEmpty ? provider.defaultModel : v
        }
        set { defaults.set(newValue, forKey: modelKey) }
    }

    /// Endpoint configurato (vuoto = default del provider).
    public static var endpoint: String {
        get { defaults.string(forKey: endpointKey) ?? "" }
        set { defaults.set(newValue, forKey: endpointKey) }
    }

    // ── Chiave API (Keychain, per provider) ───────────────────────────────────

    public static func apiKey(for provider: LLMProvider) -> String {
        var query: [String: Any] = keychainQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    public static func setAPIKey(_ key: String, for provider: LLMProvider) {
        let base = keychainQuery(provider)
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainQuery(_ provider: LLMProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    // ── Config completa ───────────────────────────────────────────────────────

    /// True se il provider corrente ha una chiave API salvata.
    public static var isConfigured: Bool { !apiKey(for: provider).isEmpty }

    /// Config pronta per il client, o nil se manca la chiave.
    public static func currentConfig() -> LLMConfig? {
        let p = provider
        let key = apiKey(for: p)
        guard !key.isEmpty else { return nil }
        return LLMConfig(provider: p, model: model, endpoint: endpoint, apiKey: key)
    }
}
