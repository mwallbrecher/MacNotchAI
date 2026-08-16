import Foundation

/// Errors specific to the hosted free-tier path (talking to our Cloudflare Worker).
enum HostedError: LocalizedError {
    /// `BackendConfig.proxyBaseURL` is nil — the Worker URL hasn't been pasted in yet.
    case backendNotConfigured
    /// The device used up its daily free allowance. `resetAt` is the ISO-8601 UTC reset time.
    case limitReached(resetAt: String?)
    /// The shared free tier hit its global daily ceiling (budget circuit-breaker).
    case serviceBusy

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "Dragaway Free isn't available yet. Switch to your own API key in Settings."
        case .limitReached:
            return "You've used today's free interactions. Try again tomorrow or use your own API key."
        case .serviceBusy:
            return "Dragaway Free is busy right now. Try again later or use your own API key."
        }
    }
}

/// AIProvider that routes completions through the hosted metering Worker instead of
/// calling a model API directly. The host Gemini key lives only on the Worker; the app
/// authenticates the device with an anonymous `X-Device-Id`. Every response carries a
/// fresh usage snapshot which we mirror into `UsageStore`.
final class HostedProvider: AIProvider {
    let name = "Dragaway Free"

    /// Only usable once the Worker URL has been configured.
    var isAvailable: Bool { BackendConfig.proxyBaseURL != nil }

    /// Wire body + headers shared by `reply` and `replyStream` — the two endpoints take
    /// an identical request and differ only in how the answer comes back.
    private func makeRequest(path: String, turns: [ChatTurn],
                             imageURL: URL?, plan: RoutingPlan) throws -> URLRequest {
        guard let base = BackendConfig.proxyBaseURL else { throw HostedError.backendNotConfigured }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")

        // Send the whole conversation: system prompt separate, user/assistant
        // turns as a messages array. The Worker forwards to the host model.
        // Fold the document back into the first user turn (flattenedContent) so the
        // Worker still receives a stable leading prefix it can cache server-side.
        let system = turns.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let messages = turns.filter { $0.role != "system" }
            .map { ["role": $0.role, "content": $0.flattenedContent] }

        // Forward the routing decision so the Worker can pick the model (`tier`) and cap
        // the output (`max_tokens`). The Worker owns the key — this is where the operator's
        // bill is actually won. `tier` is a hint: the Worker falls back to the capable
        // model if it's missing or unrecognised.
        var body: [String: Any] = [
            "system": system,
            "messages": messages,
            "max_tokens": plan.maxOutputTokens,
            "tier": plan.tier.rawValue,
        ]
        if let imageURL, FileInspector.isImageFile(imageURL),
           let imageData = try? Data(contentsOf: imageURL) {
            body["image"] = [
                "mime": Self.mimeType(for: imageURL),
                "data": imageData.base64EncodedString(),
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func reply(messages turns: [ChatTurn], imageURL: URL?, plan: RoutingPlan) async throws -> String {
        let request = try makeRequest(path: "v1/complete", turns: turns,
                                      imageURL: imageURL, plan: plan)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let decoded = try? JSONDecoder().decode(CompleteResponse.self, from: data)

        if let usage = decoded?.usage {
            UsageStore.shared.apply(usage)
        }

        switch http?.statusCode ?? 0 {
        case 200:
            guard let text = decoded?.text, !text.isEmpty else {
                throw AIError.apiError(decoded?.error ?? "Empty response")
            }
            return text
        case 429:
            throw HostedError.limitReached(resetAt: decoded?.usage?.resetAt)
        case 503:
            throw HostedError.serviceBusy
        default:
            throw AIError.apiError(decoded?.error ?? "HTTP \(http?.statusCode ?? 0)")
        }
    }

    /// Set once a deployed Worker answers `/v1/stream` with 404/405, so a fleet that
    /// hasn't been updated yet costs one probe per launch instead of one per turn.
    private static var streamingUnavailable = false

    /// Streaming variant. The Worker re-emits Gemini's OpenAI-compatible SSE and appends
    /// one terminal `{"usage":…}` event carrying the same snapshot `/v1/complete` returns
    /// in its JSON body, so the free-tier counter stays exact either way.
    ///
    /// The app and the Worker deploy independently, so an older Worker without the route
    /// must not break the turn: 404/405 falls back to the one-shot endpoint.
    func replyStream(messages turns: [ChatTurn], imageURL: URL?, plan: RoutingPlan,
                     onDelta: @escaping (String) -> Void) async throws -> String {
        guard !Self.streamingUnavailable else {
            return try await reply(messages: turns, imageURL: imageURL, plan: plan)
        }

        var request = try makeRequest(path: "v1/stream", turns: turns,
                                      imageURL: imageURL, plan: plan)
        // See openAICompatSSE: URLSession's transparent gzip decoding buffers an event
        // stream to completion, which turns streaming back into a one-shot reply.
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }   // error bodies are small
            if status == 404 || status == 405 {
                Self.streamingUnavailable = true
                return try await reply(messages: turns, imageURL: imageURL, plan: plan)
            }
            let decoded = try? JSONDecoder().decode(CompleteResponse.self, from: data)
            if let usage = decoded?.usage { UsageStore.shared.apply(usage) }
            switch status {
            case 429: throw HostedError.limitReached(resetAt: decoded?.usage?.resetAt)
            case 503: throw HostedError.serviceBusy
            default:  throw AIError.apiError(decoded?.error ?? "HTTP \(status)")
            }
        }

        struct Event: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
            }
            let choices: [Choice]?
            let usage: HostedUsage?
            let error: String?
        }

        var full = ""
        var streamError: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: d) else { continue }
            // Past the 200 the Worker can only report a failure in-band. Keep whatever
            // text already arrived — a partial answer beats discarding a metered turn.
            if let error = event.error { streamError = error; continue }
            if let usage = event.usage { UsageStore.shared.apply(usage) }
            if let delta = event.choices?.first?.delta?.content, !delta.isEmpty {
                full += delta
                onDelta(delta)
            }
        }
        if full.isEmpty { throw AIError.apiError(streamError ?? "Empty response") }
        return full
    }

    private struct CompleteResponse: Decodable {
        let text: String?
        let usage: HostedUsage?
        let error: String?
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        default:            return "image/png"
        }
    }
}
