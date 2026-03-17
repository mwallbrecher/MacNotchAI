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

    /// Model badge shown on the trailing edge of the row.
    var modelLabel: String {
        switch self {
        case .groq:      return "Llama 3.1 8B"
        case .anthropic: return "Haiku 4.5"
        case .openai:    return "GPT-4o mini"
        case .ollama:    return "local model"
        }
    }

    /// One-line pricing summary framed as "tasks per dollar" so it feels tangible.
    ///
    /// Calculation basis — typical AI Drop task ≈ 1,200 tokens in + 400 tokens out:
    ///   GPT-4o mini   $0.15/MTok in + $0.60/MTok out → ~$0.00042/task → $5 ≈ 11,900
    ///   Claude Haiku  $0.80/MTok in + $4.00/MTok out → ~$0.00256/task → $5 ≈  1,950
    ///   Groq free tier: 14,400 requests/day included at no cost
    ///   Ollama: no API, runs fully locally
    var pricingSubtitle: String {
        switch self {
        case .groq:
            return "Free tier · ~14,000 analyses/day included at no cost"
        case .anthropic:
            return "$5 ≈ ~2,000 file analyses · pay only for what you use"
        case .openai:
            return "$5 ≈ ~10,000 file analyses · pay only for what you use"
        case .ollama:
            return "Free & unlimited · runs 100% on your Mac"
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
