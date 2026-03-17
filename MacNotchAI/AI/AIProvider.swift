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

// MARK: - Display metadata (used by provider picker in Onboarding + Settings)

extension AIProviderType {

    /// Short, friendly name shown as the row title.
    var displayName: String {
        switch self {
        case .groq:      return "Groq"
        case .anthropic: return "Claude"
        case .openai:    return "ChatGPT"
        case .ollama:    return "Ollama"
        }
    }

    /// Model badge shown next to the provider name in the picker row.
    var modelLabel: String {
        switch self {
        case .groq:      return "Llama 3.1 8B"
        case .anthropic: return "Haiku 4.5"
        case .openai:    return "GPT-4o mini"
        case .ollama:    return "local model"
        }
    }

    /// One-line tagline beneath the model badge (what makes this provider special).
    var tagline: String {
        switch self {
        case .groq:      return "Fastest & cheapest"
        case .anthropic: return "Highest-quality small model"
        case .openai:    return "Best value overall"
        case .ollama:    return "Runs on your Mac"
        }
    }

    /// Human-readable cost framed as analyses per $5 — tangible without token jargon.
    ///
    /// Typical AI Drop task ≈ 1,500 tokens in + 400 tokens out:
    ///   Groq / Llama 3.1 8B   $0.05/MTok in + $0.08/MTok out → ~$0.000107/task → $5 ≈ 46,700
    ///   Claude Haiku 4.5      $0.80/MTok in + $4.00/MTok out → ~$0.00280/task  → $5 ≈    1,786  → display ~385 (conservative, longer tasks)
    ///   GPT-4o mini           $0.15/MTok in + $0.60/MTok out → ~$0.000465/task → $5 ≈   10,752  → display ~2,800 (mid-complexity tasks)
    ///   Ollama                free local inference
    var pricingSubtitle: String {
        switch self {
        case .groq:
            return "~10,000 standard analyses / $5 · Best for lightweight tasks • free tier limits apply"
        case .anthropic:
            return "~385 standard analyses / $5 · Best for premium answers, coding, long context"
        case .openai:
            return "~2,800 standard analyses / $5 · Best balance of cost, quality, and image support"
        case .ollama:
            return "Unlimited local analyses · No API bill • speed and quality depend on your hardware"
        }
    }

    /// Whether this provider requires a paid/registered API key.
    var requiresAPIKey: Bool {
        self != .ollama
    }

    /// Badge tint — green for free options, blue/default for paid.
    var isFree: Bool {
        self == .groq || self == .ollama
    }
}
