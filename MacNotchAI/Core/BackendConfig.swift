import Foundation

/// Paste-later configuration for the hosted backend + payments.
///
/// Everything here is intentionally empty until the Cloudflare Worker proxy and
/// Paddle checkout are set up (see `tasks/todo.md` → Phase 2). While
/// `proxyBaseURL == nil` the whole app stays in pure BYOK mode: the "Dragaway Free"
/// version and the Pro upgrade render as *locked / coming soon* and NEVER attempt a
/// network call. The day the backend is live you only fill in the two URLs below —
/// the locked affordances enable themselves via `isBackendLive`.
enum BackendConfig {

    static let shareBaseURLOverrideKey = "shareServiceBaseURL.v2"

    /// Base URL of the metering proxy (Cloudflare Worker), e.g. `https://api.aidrop.app`.
    // TODO: paste after backend setup. Keep `nil` to stay BYOK-only.
    static let proxyBaseURL = URL(string: "https://aidrop.aidrop.workers.dev")

    /// Base URL of the SHARE worker — a separate, open-source service from the AI proxy
    /// above (see `docs/SHARE_ARCHITECTURE.md` §4). Companies can self-host and point this
    /// at their own instance. It receives ciphertext plus bounded routing/crypto metadata;
    /// the password tier never sends its decryption key.
    static let hostedShareBaseURL = URL(string: "https://dragaway-share.aidrop.workers.dev")!

    /// The hosted endpoint is the default, but an organisation may point sharing at its own
    /// compatible v2 service. An invalid persisted override fails closed instead of silently
    /// sending an explicitly self-hosted share to Dragaway's service.
    static var shareBaseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: shareBaseURLOverrideKey) else {
            return hostedShareBaseURL
        }
        return validatedShareBaseURL(raw)
    }

    /// Accept public HTTPS endpoints. Plain HTTP is useful for local Worker development only and
    /// is therefore restricted to loopback hosts. Credentials, query strings and fragments are
    /// rejected so bearer capabilities can never be redirected into URL configuration itself.
    static func validatedShareBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }

        // A stable base URL has no trailing slash; `appendingPathComponent` then behaves the same
        // for the hosted service and for a self-hosted path prefix.
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }

    static func setShareBaseURLOverride(_ raw: String?) -> Bool {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: shareBaseURLOverrideKey)
            return true
        }
        guard let url = validatedShareBaseURL(trimmed) else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: shareBaseURLOverrideKey)
        return true
    }

    /// True once the share service is configured. Gates the Expose/Join affordances.
    static var isSharingAvailable: Bool { shareBaseURL != nil }

    /// Paddle-hosted checkout URL opened by "Upgrade". Opened in the browser.
    // TODO: paste after payment setup.
    static let paddleCheckoutURL: URL? = nil

    /// App Attest key id, if pre-provisioned. Normally minted at runtime by the
    /// attestation manager; left here only as an explicit paste-later slot.
    // TODO: optional — paste after App Attest registration, else leave nil.
    static let appAttestKeyId: String? = nil

    /// True once the hosted proxy URL is filled in. Gates every hosted/Pro
    /// affordance in the UI — the single switch that turns the locked surfaces on.
    static var isBackendLive: Bool { proxyBaseURL != nil }
}
