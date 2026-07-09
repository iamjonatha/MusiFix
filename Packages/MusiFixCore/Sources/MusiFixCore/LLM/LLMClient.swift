import Foundation

/// Provider LLM cloud supportati. La configurazione è agnostica (apikey + modello
/// + endpoint): il client adatta internamente il formato HTTP di ciascun provider.
public enum LLMProvider: String, Sendable, CaseIterable, Identifiable {
    case anthropic
    case openai
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai:    return "OpenAI (ChatGPT)"
        }
    }

    /// Endpoint di default (sovrascrivibile in configurazione).
    public var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openai:    return "https://api.openai.com/v1/chat/completions"
        }
    }

    /// Modello di default suggerito.
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openai:    return "gpt-4o"
        }
    }
}

/// Configurazione completa per una chiamata LLM. `apiKey` proviene dal Keychain.
public struct LLMConfig: Sendable {
    public let provider: LLMProvider
    public let model: String
    public let endpoint: String
    public let apiKey: String

    public init(provider: LLMProvider, model: String, endpoint: String, apiKey: String) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint.isEmpty ? provider.defaultEndpoint : endpoint
        self.apiKey = apiKey
    }
}

/// Astrazione minima e provider-agnostica: system prompt + user prompt → testo.
public protocol LLMClient: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

/// Implementazione HTTP che mappa la stessa richiesta ai formati di Anthropic e
/// OpenAI. Nessun dato provider-specifico esce dalla configurazione.
public struct HTTPLLMClient: LLMClient {
    public let config: LLMConfig
    private let session: URLSession

    public init(config: LLMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func complete(system: String, user: String, maxTokens: Int = 2048) async throws -> String {
        guard !config.apiKey.isEmpty else {
            throw MusiFixError.appleScriptError("Chiave API non configurata per \(config.provider.label)")
        }
        var request = URLRequest(url: URL(string: config.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        switch config.provider {
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ])
        case .openai:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MusiFixError.appleScriptError("Risposta LLM non valida")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MusiFixError.appleScriptError("Errore \(config.provider.label) (HTTP \(http.statusCode)): \(body.prefix(300))")
        }
        return try Self.extractText(from: data, provider: config.provider)
    }

    /// Estrae il testo dalla risposta JSON del provider.
    private static func extractText(from data: Data, provider: LLMProvider) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch provider {
        case .anthropic:
            let content = json?["content"] as? [[String: Any]]
            let text = content?.compactMap { $0["text"] as? String }.joined()
            guard let text, !text.isEmpty else {
                throw MusiFixError.appleScriptError("Risposta Claude senza testo")
            }
            return text
        case .openai:
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            guard let text = message?["content"] as? String, !text.isEmpty else {
                throw MusiFixError.appleScriptError("Risposta OpenAI senza testo")
            }
            return text
        }
    }
}
