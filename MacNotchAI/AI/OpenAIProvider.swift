import Foundation

// GPT-4o-mini — BYOK
// API key from: https://platform.openai.com

final class OpenAIProvider: AIProvider {
    let name = "OpenAI"
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o-mini"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userContent: Any = content

        if let imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            let base64 = imageData.base64EncodedString()
            let ext = imageURL.pathExtension.lowercased()
            let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "image/png"
            userContent = [
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]],
                ["type": "text", "text": action.systemPrompt]
            ]
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user",   "content": userContent]
            ],
            "max_tokens": 1024,
            "temperature": 0.3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return response.choices.first?.message.content ?? "No response"
    }
}

// Shared response model (Groq uses the same OpenAI-compatible format)
struct OpenAICompatibleResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String
        }
    }
}
