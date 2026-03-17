import Foundation

// Completely free, runs locally on Apple Silicon.
// Install from: https://ollama.ai
// Then run: ollama pull llama3.1

final class OllamaProvider: AIProvider {
    let name = "Ollama (Local)"
    private let baseURL = "http://localhost:11434/v1/chat/completions"
    private let model = "llama3.1"

    var isAvailable: Bool {
        // Synchronous check — acceptable for the settings UI only.
        // Do not call on the main thread during normal operation.
        let url = URL(string: "http://localhost:11434/api/tags")!
        var request = URLRequest(url: url, timeoutInterval: 1.0)
        request.httpMethod = "GET"
        let semaphore = DispatchSemaphore(value: 0)
        var available = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            available = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return available
    }

    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": action.systemPrompt],
                ["role": "user",   "content": content]
            ],
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        return response.choices.first?.message.content ?? "No response"
    }
}
