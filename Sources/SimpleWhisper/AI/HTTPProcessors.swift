import Foundation

/// OpenAI Chat Completions API.
final class OpenAIProcessor: TextProcessor {
    let apiKey: String
    let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func process(text: String, instructions: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProcessingError.unavailable("OpenAI API key is not set (Settings › AI)") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data: data, provider: "OpenAI")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProcessingError.commandFailed("OpenAI: unexpected response")
        }
        let output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw ProcessingError.emptyOutput }
        return output
    }

    static func check(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            var detail = "HTTP \(http.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                detail += ": \(message)"
            }
            throw ProcessingError.commandFailed("\(provider) \(detail)")
        }
    }
}

/// Google Gemini generateContent API.
final class GeminiProcessor: TextProcessor {
    let apiKey: String
    let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func process(text: String, instructions: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProcessingError.unavailable("Gemini API key is not set (Settings › AI)") }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [["text": text]]]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try OpenAIProcessor.check(response, data: data, provider: "Gemini")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw ProcessingError.commandFailed("Gemini: unexpected response")
        }
        let output = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw ProcessingError.emptyOutput }
        return output
    }
}

/// Builds the processor for a provider using the app settings.
enum AIProviderFactory {
    static let openAIKeyAccount = "openai-api-key"
    static let geminiKeyAccount = "gemini-api-key"
    static let claudeKeyAccount = "claude-api-key"

    enum Context { case prompt, command }

    /// - Parameters:
    ///   - shellTemplate: per-prompt custom command (only for `.shell`); empty = the settings default.
    ///   - context: prompts never get web access; command mode follows the setting.
    static func makeProcessor(provider: PromptProvider, shellTemplate: String, settings: AppSettings, context: Context) -> TextProcessor {
        let web = context == .command && settings.allowWebAccess
        switch provider {
        case .appleFoundationModels:
            return FoundationModelsProcessor()
        case .claudeCode:
            return ShellCommandProcessor(commandTemplate: context == .command ? settings.claudeCodeCommandCommand : settings.claudeCodePromptCommand, allowWebAccess: web)
        case .shell:
            let template = shellTemplate.trimmingCharacters(in: .whitespaces)
            let fallback = context == .command ? settings.commandShellCommand : settings.defaultShellCommand
            return ShellCommandProcessor(commandTemplate: template.isEmpty ? fallback : template, allowWebAccess: web)
        case .codex:
            return ShellCommandProcessor(commandTemplate: settings.codexCommand, allowWebAccess: web)
        case .geminiCLI:
            return ShellCommandProcessor(commandTemplate: settings.geminiCLICommand, allowWebAccess: web)
        case .agy:
            return ShellCommandProcessor(commandTemplate: settings.agyCommand, allowWebAccess: web)
        case .claudeAPI:
            return ClaudeAPIProcessor(apiKey: KeychainStore.get(claudeKeyAccount) ?? "", model: settings.claudeModel)
        case .openAI:
            return OpenAIProcessor(apiKey: KeychainStore.get(openAIKeyAccount) ?? "", model: settings.openAIModel)
        case .gemini:
            return GeminiProcessor(apiKey: KeychainStore.get(geminiKeyAccount) ?? "", model: settings.geminiModel)
        }
    }
}

/// Anthropic Messages API (raw HTTP; there is no official Swift SDK).
final class ClaudeAPIProcessor: TextProcessor {
    let apiKey: String
    let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    func process(text: String, instructions: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ProcessingError.unavailable("Claude API key is not set (Settings › AI)") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallbacks: if a safety classifier declines, the request is re-routed automatically.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": instructions,
            "fallbacks": "default",
            "messages": [["role": "user", "content": text]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try OpenAIProcessor.check(response, data: data, provider: "Claude API")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ProcessingError.commandFailed("Claude API: unexpected response")
        }
        if json["stop_reason"] as? String == "refusal" {
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String ?? "policy"
            throw ProcessingError.commandFailed("Claude API declined the request (\(category))")
        }
        let output = content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw ProcessingError.emptyOutput }
        return output
    }
}
