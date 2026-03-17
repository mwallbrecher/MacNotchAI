import Foundation

enum AIError: LocalizedError {
    case noAPIKey(provider: String)
    case apiError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let provider):
            return "No API key for \(provider). Open Settings (⌘,) to add one."
        case .apiError(let msg):
            return msg
        case .httpError(let code):
            return "Request failed (HTTP \(code))."
        }
    }
}

// Shared helper used by all providers.
extension Data {
    /// Tries to extract a human-readable message from an API error body.
    func apiErrorMessage() -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: self) as? [String: Any] else { return nil }
        // OpenAI / Groq style: { "error": { "message": "..." } }
        if let error = json["error"] as? [String: Any],
           let msg = error["message"] as? String { return msg }
        // Anthropic style: { "error": { "message": "..." } } — same shape, covered above.
        return nil
    }
}
