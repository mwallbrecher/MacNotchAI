import Foundation

// THESIS (L4 support) — a deliberately short-lived, RAM-only bridge between the
// clipboard sensor and the summoned discovery action.
//
// Raw clipboard content must never cross SignalBus or enter a trace. Discovery is
// nevertheless a multi-object task: once the pasteboard advances, a hash/embedding
// cannot be handed to a model. This vault retains only a small, bounded set of recent
// text copies in process memory. It has no Codable conformance, persistence hook, URL,
// UserDefaults key, or exporter surface. stop/suspend clears it.
@MainActor
final class IntentContentVault {
    static let shared = IntentContentVault()

    struct Reference: Hashable, Sendable {
        let hash: String
        let capturedAt: TimeInterval
    }

    struct Snapshot: Sendable {
        let references: [Reference]

        var newestHash: String? { references.last?.hash }
        var count: Int { references.count }
    }

    private struct Entry {
        let reference: Reference
        let text: String
    }

    static let lifetime: TimeInterval = 90
    private static let maximumEntries = 3
    private static let maximumCharactersPerEntry = 6_000
    private static let maximumTotalCharacters = 18_000

    private var entries: [Entry] = []

    private init() {}

    func store(text raw: String, hash: String, at t: TimeInterval) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hash.isEmpty else { return }

        prune(at: t)
        entries.removeAll { $0.reference.hash == hash }
        let bounded = String(trimmed.prefix(Self.maximumCharactersPerEntry))
        entries.append(Entry(reference: Reference(hash: hash, capturedAt: t), text: bounded))
        enforceBounds()
    }

    func snapshot(at t: TimeInterval) -> Snapshot {
        prune(at: t)
        return Snapshot(references: entries.map(\.reference))
    }

    /// Resolves the exact snapshot captured when the ticker was shown. A refreshed,
    /// evicted, or expired entry fails instead of silently substituting different text.
    func texts(matching references: [Reference], at t: TimeInterval) -> [String]? {
        prune(at: t)
        guard !references.isEmpty else { return nil }

        var result: [String] = []
        result.reserveCapacity(references.count)
        for reference in references {
            guard let entry = entries.first(where: { $0.reference == reference }) else { return nil }
            result.append(entry.text)
        }
        return result
    }

    /// Erases the exact sources once their bounded text has been copied into an
    /// accepted session. This shortens their residence below even the 90-second TTL.
    func discard(_ references: [Reference]) {
        let accepted = Set(references)
        entries.removeAll { accepted.contains($0.reference) }
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    private func prune(at t: TimeInterval) {
        entries.removeAll { t - $0.reference.capturedAt > Self.lifetime || t < $0.reference.capturedAt }
    }

    private func enforceBounds() {
        while entries.count > Self.maximumEntries {
            entries.removeFirst()
        }
        var total = entries.reduce(0) { $0 + $1.text.count }
        while total > Self.maximumTotalCharacters, entries.count > 1 {
            total -= entries.removeFirst().text.count
        }
    }
}
