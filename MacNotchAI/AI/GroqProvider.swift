import Foundation

// Groq offers a free tier — ideal default for new users, no credit card needed.
// Sign up at: https://console.groq.com

final class GroqProvider: AIProvider {
    let name = "Groq"
    private let apiKey: String
    private let baseURL = "https://api.groq.com/openai/v1/chat/completions"
    private let model = "llama-3.1-8b-instant"

    init(apiKey: String) { self.apiKey = apiKey }

    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey(provider: name) }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user",   "content": content]
            ],
            "max_tokens": 1024,
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.apiError(data.apiErrorMessage() ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return decoded.choices.first?.message.content ?? "No response"
    }
}
