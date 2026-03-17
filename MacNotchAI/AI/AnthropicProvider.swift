import Foundation

// Claude Haiku — cheapest option for BYOK users.
// API key from: https://console.anthropic.com

final class AnthropicProvider: AIProvider {
    let name = "Anthropic"
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-haiku-4-5-20251001"

    init(apiKey: String) { self.apiKey = apiKey }
    var isAvailable: Bool { !apiKey.isEmpty }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = []

        if let imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            let base64 = imageData.base64EncodedString()
            let mime = mimeType(for: imageURL)
            messages.append([
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]],
                    ["type": "text", "text": action.systemPrompt]
                ]
            ])
        } else {
            messages.append(["role": "user", "content": content])
        }

        let body: [String: Any] = [
            "model": model,
            "system": action.systemPrompt,
            "messages": messages,
            "max_tokens": 1024
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return response.content.first?.text ?? "No response"
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        default:            return "image/jpeg"
        }
    }
}

struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    struct ContentBlock: Decodable {
        let text: String
    }
}
