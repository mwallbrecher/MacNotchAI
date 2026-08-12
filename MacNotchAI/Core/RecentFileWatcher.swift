import AppKit
import Combine
import CoreServices
import Foundation

/// Permission-free, push-based source for “the last file I saved”.
///
/// The stream observes only filesystem paths and metadata. It never extracts file content; the
/// normal session pipeline starts doing that only after the user presses ⌃⌘L. Candidate state is
/// deliberately memory-only and bounded, so this feature creates no activity log on disk.
@MainActor
final class RecentFileWatcher: NSObject, ObservableObject {
    static let shared = RecentFileWatcher()

    @Published private(set) var latestFileURL: URL?
    @Published private(set) var isWatching = false
    @Published private(set) var isShortcutAvailable = false
    @Published private(set) var hasCompletedBootstrap = false

    private nonisolated enum Source: Sendable, Equatable {
        case live(FSEventStreamEventId)
        case bootstrap(Date)
    }

    private nonisolated struct PendingCandidate: Sendable {
        let url: URL
        let source: Source
        let validationRetry: Int

        init(url: URL, source: Source, validationRetry: Int = 0) {
            self.url = url
            self.source = source
            self.validationRetry = validationRetry
        }
    }

    private nonisolated struct Candidate: Sendable {
        let url: URL
        let modifiedAt: Date
        let source: Source
    }

    private nonisolated struct Fingerprint: Sendable, Equatable {
        let byteCount: Int
        let modifiedAt: Date
    }

    private nonisolated struct ValidatedCandidate: Sendable {
        let pending: PendingCandidate
        let fingerprint: Fingerprint
    }

    private nonisolated enum ValidationResult: Sendable {
        case stable(ValidatedCandidate)
        case invalid(PendingCandidate)
        case changing(PendingCandidate)
    }

    private nonisolated struct BootstrapSeed: Sendable {
        let path: String
        let modifiedAt: Date
    }

    private nonisolated enum StabilityProbe: Sendable {
        case stable(Fingerprint)
        case invalid
        case changing
    }

    private var stream: FSEventStreamRef?
    private let streamQueue = DispatchQueue(
        label: "com.aidrop.recent-files.fsevents", qos: .utility
    )
    private var streamCallbackContext: RecentFileCallbackContext?
    private var metadataQuery: NSMetadataQuery?
    private var bootstrapProcessingTask: Task<Void, Never>?
    private var bootstrapToken = UUID()
    private var isBootstrapInProgress = false
    private var generation = UUID()
    private var activityRevision: UInt64 = 0
    private var pending: [String: PendingCandidate] = [:]
    /// Live paths remain here from first event until stable validation or removal. This prevents a
    /// failed/long write from making the hotkey silently fall back to an older file.
    private var unresolvedLive: [String: PendingCandidate] = [:]
    private var candidates: [Candidate] = []
    private var validationTask: Task<Void, Never>?
    private var validationToken = UUID()
    private var isValidationRunning = false

    private nonisolated static let maximumPendingCount = 128
    private nonisolated static let maximumUnresolvedCount = 128
    private nonisolated static let maximumCandidateCount = 12
    private nonisolated static let maximumBootstrapInspectionCount = 4_096
    private nonisolated static let temporarySuffixes = [
        ".tmp", ".temp", ".part", ".partial", ".download", ".crdownload",
        ".icloud", ".swp", ".lock", ".bak",
    ]
    private nonisolated static let noisyComponents: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "deriveddata", "build", ".build",
        "pods", "carthage", "__pycache__", ".venv", "venv", "caches", "cache",
    ]
    private nonisolated static let sensitiveNames: Set<String> = [
        "credentials.json", "secrets.json", "key.properties", "service-account.json",
        "serviceaccount.json", "google-services.json",
    ]
    private nonisolated static let dragawaySupportPath = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("com.wallbrecher.MacNotchAI", isDirectory: true).path

    private override init() { super.init() }

    func setShortcutAvailable(_ available: Bool) {
        isShortcutAvailable = available
    }

    /// Rebuild the stream from the current settings. FSEvents roots are fixed at stream creation,
    /// so add/remove/exclude changes intentionally restart it and invalidate all in-flight work.
    func reconfigure() {
        stop(clearCandidates: true)

        let settings = RecentFileSettings.shared
        guard settings.isEnabled else { return }

        let roots = settings.watchedFolders.filter {
            var isDirectory: ObjCBool = false
            return settings.contains($0.path)
                && FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard !roots.isEmpty else { return }

        generation = UUID()
        guard startStream(roots: roots) else { return }
        isWatching = true
        startBootstrapQuery(roots: roots)
    }

    func stop(clearCandidates: Bool = true) {
        generation = UUID()
        activityRevision &+= 1
        validationToken = UUID()
        validationTask?.cancel()
        validationTask = nil
        isValidationRunning = false
        bootstrapToken = UUID()
        bootstrapProcessingTask?.cancel()
        bootstrapProcessingTask = nil
        isBootstrapInProgress = false
        hasCompletedBootstrap = false
        pending.removeAll(keepingCapacity: false)
        unresolvedLive.removeAll(keepingCapacity: false)
        stopBootstrapQuery()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            // The context pointer is unretained. Drain the serial callback queue before releasing
            // its owner so an in-flight C callback can never dereference freed memory.
            streamQueue.sync {}
        }
        streamCallbackContext = nil
        isWatching = false

        if clearCandidates {
            candidates.removeAll(keepingCapacity: false)
            latestFileURL = nil
        }
    }

    /// Flush pending filesystem events and wait for a bounded quiet revision before choosing. This
    /// avoids opening yesterday's candidate when a save event arrives just after the shortcut, and
    /// revalidates the final path in case a previously safe file was replaced by a symlink/package.
    func resolveLatestFile() async -> URL? {
        guard !Task.isCancelled, RecentFileSettings.shared.isEnabled else { return nil }

        if let stream { FSEventStreamFlushAsync(stream) }
        let deadline = Date().addingTimeInterval(2.8)
        var observedRevision = activityRevision
        var quietSince = Date()

        settleLoop: while Date() < deadline {
            let remainingMilliseconds = max(
                1, min(110, Int(deadline.timeIntervalSinceNow * 1_000))
            )
            try? await Task.sleep(for: .milliseconds(remainingMilliseconds))
            guard !Task.isCancelled,
                  Date() < deadline,
                  RecentFileSettings.shared.isEnabled else { return nil }

            if activityRevision != observedRevision {
                observedRevision = activityRevision
                quietSince = Date()
            }
            if activityRevision != observedRevision {
                observedRevision = activityRevision
                quietSince = Date()
                continue
            }
            guard pending.isEmpty, !isValidationRunning,
                  Date().timeIntervalSince(quietSince) >= 0.25 else { continue }

            // A live event is authoritative and must not wait for an unrelated, slow Spotlight
            // bootstrap. Bootstrap is awaited only when it is our sole way to find a candidate.
            if isBootstrapInProgress, !hasLiveWork { continue }

            // Only an unresolved event newer than the best stable candidate may block it. An older
            // long-running export must never suppress a newer document that has already stabilised.
            while let item = newestBlockingUnresolved {
                guard deadline.timeIntervalSinceNow >= 0.19 else { return nil }
                let validationRevision = activityRevision
                guard passesFastPolicy(item.url) else {
                    clearUnresolved(item)
                    continue
                }
                switch await probeStabilityOffMain(item.url) {
                case let .stable(fingerprint):
                    guard activityRevision == validationRevision else {
                        observedRevision = activityRevision
                        quietSince = Date()
                        continue settleLoop
                    }
                    addCandidate(Candidate(
                        url: item.url,
                        modifiedAt: fingerprint.modifiedAt,
                        source: item.source
                    ))
                case .invalid:
                    clearUnresolved(item)
                case .changing:
                    continue settleLoop
                }
                guard !Task.isCancelled, Date() < deadline else { return nil }
            }

            while let candidate = candidates.first {
                let validationRevision = activityRevision
                guard passesFastPolicy(candidate.url) else {
                    candidates.removeFirst()
                    publishLatestCandidate()
                    continue settleLoop
                }
                guard deadline.timeIntervalSinceNow >= 0.19 else { return nil }
                let probe = await probeStabilityOffMain(candidate.url)
                guard !Task.isCancelled, Date() < deadline else { return nil }
                if activityRevision != validationRevision {
                    observedRevision = activityRevision
                    quietSince = Date()
                    continue settleLoop
                }
                switch probe {
                case .stable:
                    latestFileURL = candidate.url
                    return candidate.url
                case .invalid:
                    candidates.removeFirst()
                    publishLatestCandidate()
                    continue settleLoop
                case .changing:
                    continue settleLoop
                }
            }
            return nil
        }

        // A continuously-changing file is not safe to open automatically. Beep rather than silently
        // falling back to an older file while a newer candidate is still unresolved.
        return nil
    }

    // MARK: - FSEvents

    private func startStream(roots: [URL]) -> Bool {
        let settings = RecentFileSettings.shared
        let callbackContext = RecentFileCallbackContext(
            watcher: self,
            generation: generation,
            policy: RecentFilePolicySnapshot(
                watchedRoots: settings.watchedPaths,
                excludedRoots: settings.excludedPaths
            )
        )
        streamCallbackContext = callbackContext
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            nil,
            recentFileFSEventCallback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.45,
            flags
        ) else {
            streamCallbackContext = nil
            return false
        }

        // CoreServices can suppress at most eight paths before delivery. User-space policy below
        // still checks every exclusion, but this prevents a home-folder watch from waking Dragaway
        // for high-churn trees such as ~/Library in the common case.
        let streamExclusions = Array(settings.excludedPaths.filter { excluded in
            roots.contains(where: { RecentFileSettings.contains(root: $0.path, path: excluded) })
                && FileManager.default.fileExists(atPath: excluded)
        }.prefix(8))
        if !streamExclusions.isEmpty {
            _ = FSEventStreamSetExclusionPaths(created, streamExclusions as CFArray)
        }

        FSEventStreamSetDispatchQueue(created, streamQueue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            streamCallbackContext = nil
            return false
        }
        stream = created
        return true
    }

    fileprivate func receive(
        _ events: [RecentFileRawEvent],
        generation callbackGeneration: UUID,
        needsBootstrap: Bool,
        needsReconfigure: Bool
    ) {
        guard callbackGeneration == generation, RecentFileSettings.shared.isEnabled else { return }
        if !events.isEmpty || needsBootstrap || needsReconfigure { activityRevision &+= 1 }

        for event in events {
            let flags = event.flags
            let url = URL(fileURLWithPath: RecentFileSettings.normalizedPath(event.path))
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                removePath(url.path)
                continue
            }
            guard passesFastPolicy(url) else { continue }
            enqueue(PendingCandidate(url: url, source: .live(event.id)))
        }

        if needsReconfigure {
            Task { @MainActor [weak self] in self?.reconfigure() }
        } else if needsBootstrap {
            startBootstrapQuery(roots: RecentFileSettings.shared.watchedFolders)
        }
    }

    // MARK: - Candidate stability

    private func enqueue(_ newCandidate: PendingCandidate) {
        let path = newCandidate.url.path
        if let existing = pending[path], !Self.isNewer(newCandidate.source, than: existing.source) {
            return
        }
        activityRevision &+= 1
        pending[path] = newCandidate
        if case .live = newCandidate.source {
            if let existing = unresolvedLive[path],
               !Self.isNewer(newCandidate.source, than: existing.source) {
                // Keep the newer unresolved event already tracked for this path.
            } else {
                unresolvedLive[path] = newCandidate
            }
            trimUnresolvedIfNeeded()
        }

        if pending.count > Self.maximumPendingCount,
           let oldest = pending.min(by: {
               Self.isNewer($1.value.source, than: $0.value.source)
           })?.key {
            if let removed = pending.removeValue(forKey: oldest),
               unresolvedLive[oldest]?.source == removed.source {
                unresolvedLive.removeValue(forKey: oldest)
            }
        }
        scheduleValidation()
    }

    private func scheduleValidation() {
        validationTask?.cancel()
        let expectedGeneration = generation
        let expectedToken = UUID()
        validationToken = expectedToken
        isValidationRunning = true
        validationTask = Task { [weak self] in
            defer {
                self?.finishValidation(
                    expectedGeneration: expectedGeneration,
                    expectedToken: expectedToken
                )
            }
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            await self?.drainPending(expectedGeneration: expectedGeneration)
        }
    }

    private func finishValidation(expectedGeneration: UUID, expectedToken: UUID) {
        guard generation == expectedGeneration, validationToken == expectedToken else { return }
        validationTask = nil
        isValidationRunning = false
    }

    private func drainPending(expectedGeneration: UUID) async {
        guard generation == expectedGeneration, !pending.isEmpty else { return }
        let batch = Array(pending.values)
            .sorted { Self.isNewer($0.source, than: $1.source) }
            .prefix(32)
        for item in batch { pending.removeValue(forKey: item.url.path) }

        let validationResults = await withTaskGroup(of: ValidationResult.self) { group in
            for item in batch {
                group.addTask { await Self.validate(item) }
            }
            var results: [ValidationResult] = []
            for await result in group { results.append(result) }
            return results
        }

        guard !Task.isCancelled, generation == expectedGeneration else { return }
        for result in validationResults {
            switch result {
            case let .stable(validated):
                guard passesFastPolicy(validated.pending.url) else {
                    clearUnresolved(validated.pending)
                    continue
                }
                addCandidate(Candidate(
                    url: validated.pending.url,
                    modifiedAt: validated.fingerprint.modifiedAt,
                    source: validated.pending.source
                ))
            case let .invalid(item):
                clearUnresolved(item)
            case let .changing(item):
                // One bounded retry catches a write that ended during the first probe even if its
                // final filesystem event was coalesced. Newer events for the path always win.
                requeueChanging(item)
            }
        }
        publishLatestCandidate()

        if !pending.isEmpty { scheduleValidation() }
    }

    private nonisolated static func validate(_ candidate: PendingCandidate) async
        -> ValidationResult {
        for attempt in 0..<4 {
            guard !Task.isCancelled else { return .changing(candidate) }
            guard let first = fingerprint(candidate.url) else { return .invalid(candidate) }
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return .changing(candidate) }
            guard let second = fingerprint(candidate.url) else { return .invalid(candidate) }
            if first == second {
                return .stable(ValidatedCandidate(pending: candidate, fingerprint: second))
            }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(220)) }
        }
        return .changing(candidate)
    }

    private func probeStabilityOffMain(_ url: URL) async -> StabilityProbe {
        await Task.detached(priority: .userInitiated) {
            guard let first = Self.fingerprint(url) else { return .invalid }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let second = Self.fingerprint(url) else { return .invalid }
            return first == second ? .stable(second) : .changing
        }.value
    }

    private nonisolated static func fingerprint(_ url: URL) -> Fingerprint? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey,
            .isPackageKey, .isHiddenKey, .isReadableKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isAliasFile != true,
              values.isPackage != true,
              values.isHidden != true,
              values.isReadable != false,
              let byteCount = values.fileSize, byteCount > 0,
              let modifiedAt = values.contentModificationDate
        else { return nil }
        return Fingerprint(byteCount: byteCount, modifiedAt: modifiedAt)
    }

    private func addCandidate(_ candidate: Candidate) {
        if let unresolved = unresolvedLive[candidate.url.path],
           !Self.isNewer(unresolved.source, than: candidate.source) {
            unresolvedLive.removeValue(forKey: candidate.url.path)
        }
        candidates.removeAll { $0.url.path == candidate.url.path }
        candidates.append(candidate)
        candidates.sort { lhs, rhs in
            if lhs.source != rhs.source { return Self.isNewer(lhs.source, than: rhs.source) }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        if candidates.count > Self.maximumCandidateCount {
            candidates.removeLast(candidates.count - Self.maximumCandidateCount)
        }
    }

    private func removePath(_ path: String) {
        let normalized = RecentFileSettings.normalizedPath(path)
        activityRevision &+= 1
        pending.removeValue(forKey: normalized)
        unresolvedLive.removeValue(forKey: normalized)
        candidates.removeAll { $0.url.path == normalized }
        publishLatestCandidate()
    }

    private func publishLatestCandidate() {
        latestFileURL = candidates.first?.url
    }

    private var hasLiveWork: Bool {
        candidates.contains { Self.isLive($0.source) }
            || pending.values.contains { Self.isLive($0.source) }
            || unresolvedLive.values.contains { Self.isLive($0.source) }
    }

    private var newestBlockingUnresolved: PendingCandidate? {
        let stableSource = candidates.first?.source
        return unresolvedLive.values
            .filter { item in
                guard let stableSource else { return true }
                return Self.isNewer(item.source, than: stableSource)
            }
            .sorted { Self.isNewer($0.source, than: $1.source) }
            .first
    }

    private func clearUnresolved(_ item: PendingCandidate) {
        guard unresolvedLive[item.url.path]?.source == item.source else { return }
        unresolvedLive.removeValue(forKey: item.url.path)
    }

    private func requeueChanging(_ item: PendingCandidate) {
        guard item.validationRetry < 1,
              unresolvedLive[item.url.path]?.source == item.source else { return }
        let retry = PendingCandidate(
            url: item.url,
            source: item.source,
            validationRetry: item.validationRetry + 1
        )
        if let existing = pending[item.url.path],
           !Self.isNewer(retry.source, than: existing.source) { return }
        activityRevision &+= 1
        pending[item.url.path] = retry
    }

    private func trimUnresolvedIfNeeded() {
        guard unresolvedLive.count > Self.maximumUnresolvedCount else { return }
        let overflow = unresolvedLive.values
            .sorted { Self.isNewer($0.source, than: $1.source) }
            .dropFirst(Self.maximumUnresolvedCount)
        for item in overflow { clearUnresolved(item) }
    }

    // MARK: - One-shot Spotlight bootstrap

    private func startBootstrapQuery(roots: [URL]) {
        bootstrapToken = UUID()
        bootstrapProcessingTask?.cancel()
        bootstrapProcessingTask = nil
        stopBootstrapQuery()
        isBootstrapInProgress = false
        hasCompletedBootstrap = false

        let activeRoots = roots.filter {
            var isDirectory: ObjCBool = false
            return RecentFileSettings.shared.contains($0.path)
                && FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard !activeRoots.isEmpty else {
            hasCompletedBootstrap = true
            return
        }

        let query = NSMetadataQuery()
        let supportedNames = FileInspector.recentFileExtensions.map {
            NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, "*.\($0)")
        }
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemFSInvisible != 1"),
            NSCompoundPredicate(orPredicateWithSubpredicates: supportedNames),
        ])
        query.searchScopes = activeRoots
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false),
        ]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bootstrapFinished(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        metadataQuery = query
        isBootstrapInProgress = true
        if !query.start() {
            stopBootstrapQuery()
            isBootstrapInProgress = false
            hasCompletedBootstrap = true
        }
    }

    @objc private func bootstrapFinished(_ notification: Notification) {
        guard let query = metadataQuery,
              (notification.object as? NSMetadataQuery) === query else {
            return
        }
        query.disableUpdates()
        let expectedToken = bootstrapToken
        let expectedGeneration = generation

        // Reading query results is an NSMetadataQuery operation, so do it on MainActor—but in small
        // yielded batches. Path resolution and policy filtering (the filesystem-I/O portion) then
        // run on a detached utility task. A large source tree can therefore never monopolise one UI
        // runloop turn.
        bootstrapProcessingTask = Task { [weak self, query] in
            guard let self else { return }
            let count = min(query.resultCount, Self.maximumBootstrapInspectionCount)
            var rawSeeds: [BootstrapSeed] = []
            rawSeeds.reserveCapacity(count)
            var index = 0
            while index < count {
                guard !Task.isCancelled,
                      bootstrapToken == expectedToken,
                      generation == expectedGeneration,
                      metadataQuery === query else { return }
                let end = min(index + 128, count)
                for resultIndex in index..<end {
                    guard let item = query.result(at: resultIndex) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          let date = item.value(
                            forAttribute: NSMetadataItemFSContentChangeDateKey
                          ) as? Date
                    else { continue }
                    rawSeeds.append(BootstrapSeed(path: path, modifiedAt: date))
                }
                index = end
                if index < count { await Task.yield() }
            }

            guard !Task.isCancelled,
                  bootstrapToken == expectedToken,
                  generation == expectedGeneration else { return }
            stopBootstrapQuery()

            let settings = RecentFileSettings.shared
            let policy = RecentFilePolicySnapshot(
                watchedRoots: settings.watchedPaths,
                excludedRoots: settings.excludedPaths
            )
            let filteringTask = Task.detached(priority: .utility) {
                Self.filterBootstrapSeeds(rawSeeds, policy: policy)
            }
            let seeds = await withTaskCancellationHandler(
                operation: { await filteringTask.value },
                onCancel: { filteringTask.cancel() }
            )
            guard !Task.isCancelled,
                  bootstrapToken == expectedToken,
                  generation == expectedGeneration else { return }

            for seed in seeds { enqueue(seed) }
            isBootstrapInProgress = false
            hasCompletedBootstrap = true
            bootstrapProcessingTask = nil
        }
    }

    private func stopBootstrapQuery() {
        guard let query = metadataQuery else { return }
        query.stop()
        NotificationCenter.default.removeObserver(
            self, name: .NSMetadataQueryDidFinishGathering, object: query
        )
        metadataQuery = nil
    }

    private nonisolated static func filterBootstrapSeeds(
        _ rawSeeds: [BootstrapSeed],
        policy: RecentFilePolicySnapshot
    ) -> [PendingCandidate] {
        var seeds: [PendingCandidate] = []
        seeds.reserveCapacity(min(rawSeeds.count, maximumCandidateCount))
        for raw in rawSeeds {
            guard !Task.isCancelled else { break }
            guard let path = policy.normalizedAllowedPath(raw.path) else { continue }
            seeds.append(PendingCandidate(
                url: URL(fileURLWithPath: path),
                source: .bootstrap(raw.modifiedAt)
            ))
            if seeds.count >= maximumCandidateCount { break }
        }
        return seeds
    }

    // MARK: - Policy

    private func passesFastPolicy(_ url: URL) -> Bool {
        let path = RecentFileSettings.normalizedPath(url.path)
        let normalizedURL = URL(fileURLWithPath: path)
        return RecentFileSettings.shared.contains(path)
            && Self.isSafeCandidatePath(path)
            && FileInspector.isKnownRecentFileType(normalizedURL)
    }

    fileprivate nonisolated static func isSafeCandidatePath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent.lowercased()
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }

        guard !temporarySuffixes.contains(where: name.hasSuffix) else { return false }

        let components = url.pathComponents.map { $0.lowercased() }
        guard !components.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }),
              noisyComponents.isDisjoint(with: components)
        else { return false }

        guard !sensitiveNames.contains(name),
              !name.hasPrefix("credential."), !name.hasPrefix("credentials."),
              !name.hasPrefix("secret."), !name.hasPrefix("secrets.")
        else { return false }

        if let support = dragawaySupportPath,
           RecentFileSettings.contains(root: support, path: url.path) { return false }
        return true
    }

    private nonisolated static func isNewer(_ lhs: Source, than rhs: Source) -> Bool {
        switch (lhs, rhs) {
        case let (.live(left), .live(right)):             return left > right
        case (.live, .bootstrap):                         return true
        case (.bootstrap, .live):                         return false
        case let (.bootstrap(left), .bootstrap(right)):   return left > right
        }
    }

    private nonisolated static func isLive(_ source: Source) -> Bool {
        if case .live = source { return true }
        return false
    }
}

fileprivate nonisolated struct RecentFileRawEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let id: FSEventStreamEventId
}

fileprivate nonisolated struct RecentFilePolicySnapshot: Sendable {
    let watchedRoots: [String]
    let excludedRoots: [String]

    func allows(_ path: String) -> Bool {
        normalizedAllowedPath(path) != nil
    }

    func normalizedAllowedPath(_ path: String) -> String? {
        let normalized = RecentFileSettings.normalizedPath(path)
        guard watchedRoots.contains(where: {
            RecentFileSettings.contains(root: $0, path: normalized)
        }) else { return nil }
        guard !excludedRoots.contains(where: {
            RecentFileSettings.contains(root: $0, path: normalized)
        }) else { return nil }
        let url = URL(fileURLWithPath: normalized)
        guard RecentFileWatcher.isSafeCandidatePath(normalized),
              FileInspector.isKnownRecentFileType(url) else { return nil }
        return normalized
    }
}

/// Immutable callback state kept alive by `RecentFileWatcher` until its serial queue drains.
fileprivate nonisolated final class RecentFileCallbackContext: @unchecked Sendable {
    weak var watcher: RecentFileWatcher?
    let generation: UUID
    let policy: RecentFilePolicySnapshot

    init(
        watcher: RecentFileWatcher,
        generation: UUID,
        policy: RecentFilePolicySnapshot
    ) {
        self.watcher = watcher
        self.generation = generation
        self.policy = policy
    }
}

/// Bare callback required by CoreServices. It runs on a private utility queue, rejects irrelevant
/// paths there, and forwards at most 128 newest events to MainActor per batch.
private nonisolated func recentFileFSEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ context: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let context else { return }
    let callbackContext = Unmanaged<RecentFileCallbackContext>
        .fromOpaque(context).takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var events: [RecentFileRawEvent] = []
    let maximumForwardedEvents = 128
    events.reserveCapacity(min(eventCount, maximumForwardedEvents))
    var nextReplacementIndex = 0
    var needsBootstrap = false
    var needsReconfigure = false

    for index in 0..<eventCount {
        let flags = eventFlags[index]
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            needsReconfigure = true
            continue
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
            || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 {
            needsBootstrap = true
            continue
        }

        let relevant = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemCloned
                | kFSEventStreamEventFlagItemRemoved
        ) != 0
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        guard relevant, !isDirectory, let pathPointer = paths[index] else { continue }
        let path = String(cString: pathPointer)
        guard callbackContext.policy.allows(path) else { continue }

        let event = RecentFileRawEvent(path: path, flags: flags, id: eventIDs[index])
        if events.count < maximumForwardedEvents {
            events.append(event)
        } else {
            events[nextReplacementIndex] = event
            nextReplacementIndex = (nextReplacementIndex + 1) % maximumForwardedEvents
        }
    }

    if events.count == maximumForwardedEvents, nextReplacementIndex != 0 {
        events = Array(events[nextReplacementIndex...]) + Array(events[..<nextReplacementIndex])
    }
    guard !events.isEmpty || needsBootstrap || needsReconfigure,
          let watcher = callbackContext.watcher else { return }
    let generation = callbackContext.generation
    let forwardedEvents = events
    let bootstrapRequired = needsBootstrap
    let reconfigureRequired = needsReconfigure
    DispatchQueue.main.async { [weak watcher] in
        MainActor.assumeIsolated {
            watcher?.receive(
                forwardedEvents,
                generation: generation,
                needsBootstrap: bootstrapRequired,
                needsReconfigure: reconfigureRequired
            )
        }
    }
}
