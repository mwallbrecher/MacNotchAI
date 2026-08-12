import Foundation

/// The small, immutable filesystem snapshot needed by the file cards and browser.
/// Reading it may touch iCloud or a network volume, so snapshots are produced off-main
/// and views render only these cached values.
struct FilePresentationMetadata: Sendable, Equatable {
    let isDirectory: Bool
    let byteCount: Int64?

    var detail: String {
        if isDirectory { return "Folder" }
        guard let byteCount else { return "—" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    nonisolated static func read(from url: URL) -> FilePresentationMetadata {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDirectory = values?.isDirectory == true
        return FilePresentationMetadata(
            isDirectory: isDirectory,
            byteCount: isDirectory ? nil : values?.fileSize.map(Int64.init)
        )
    }
}

/// Process-local presentation cache. It deliberately stores only a few hundred tiny
/// value snapshots; file bytes and extracted content never enter this cache.
@MainActor
final class FilePresentationMetadataCache {
    static let shared = FilePresentationMetadataCache()

    private let entryLimit = 256
    private var entries: [String: FilePresentationMetadata] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: [String: Task<FilePresentationMetadata, Never>] = [:]

    private init() {}

    static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    func metadata(for url: URL) async -> FilePresentationMetadata {
        let key = Self.key(for: url)
        if let cached = entries[key] { return cached }
        return await metadata(for: [url])[key]
            ?? FilePresentationMetadata(isDirectory: false, byteCount: nil)
    }

    /// Starts every uncached filesystem read before awaiting any of them, so a gallery
    /// backed by a slow volume does not serialize one metadata round-trip per row.
    func metadata(for urls: [URL]) async -> [String: FilePresentationMetadata] {
        var result: [String: FilePresentationMetadata] = [:]
        var jobs: [(key: String, task: Task<FilePresentationMetadata, Never>)] = []

        for url in urls {
            let key = Self.key(for: url)
            if let cached = entries[key] {
                result[key] = cached
                continue
            }

            if let existing = inFlight[key] {
                jobs.append((key, existing))
                continue
            }

            let task = Task.detached(priority: .utility) {
                FilePresentationMetadata.read(from: url)
            }
            inFlight[key] = task
            jobs.append((key, task))
        }

        for job in jobs {
            let value = await job.task.value
            inFlight.removeValue(forKey: job.key)
            insert(value, forKey: job.key)
            result[job.key] = value
        }

        return result
    }

    private func insert(_ value: FilePresentationMetadata, forKey key: String) {
        if entries[key] == nil {
            while entries.count >= entryLimit, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                entries.removeValue(forKey: oldest)
            }
            insertionOrder.append(key)
        }
        entries[key] = value
    }
}
