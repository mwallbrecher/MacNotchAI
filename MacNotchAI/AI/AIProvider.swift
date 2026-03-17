import Foundation

protocol AIProvider {
    var name: String { get }
    var isAvailable: Bool { get }
    func complete(action: AIAction, content: String, imageURL: URL?) async throws -> String
}

enum AIProviderType: String, CaseIterable {
    case groq       = "Groq (Free)"
    case anthropic  = "Anthropic (Claude)"
    case openai     = "OpenAI (GPT-4o)"
    case ollama     = "Ollama (Local, Free)"
}
