import Foundation
import Combine

extension Notification.Name {
    static let intentTraceRecorderFailed = Notification.Name(
        "com.aidrop.thesis.intentTraceRecorderFailed"
    )
}

private struct TraceTailRecovery: Codable {
    let file: String
    let action: String
    let affectedBytes: UInt64
    let recoveredWallTime: TimeInterval
}

private struct TraceRecoveryJournal: Codable {
    let v: Int
    let recovery: TraceTailRecovery
}

/// Durable evidence that the trace writer stopped before it could describe its own
/// failure. The next successful recorder turns this into the first synchronized
/// `capture_failed` activity record of its new trace, then removes the journal.
private struct TraceWriterFailureJournal: Codable {
    let v: Int
    let failedWallTime: TimeInterval
    let failedUptime: TimeInterval
    let sessionID: String
    let processID: Int32
    let kind: String
}

// THESIS — fail-closed JSONL recorder. A green status means a header exists, the
// handle is open, and every counted event was written successfully.
final class TraceRecorder {

    enum RecorderError: LocalizedError {
        case directoryUnavailable(String)
        case alreadyRecording
        case createFailed(String)
        case openFailed(String)
        case encodeFailed(String)
        case writeFailed(String)
        case flushFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryUnavailable(let why): return "Trace directory unavailable: \(why)"
            case .alreadyRecording: return "Trace recording is already active."
            case .createFailed(let path): return "Could not create trace file at \(path)."
            case .openFailed(let path): return "Could not open trace file at \(path)."
            case .encodeFailed(let why): return "Could not encode trace data: \(why)"
            case .writeFailed(let why): return "Trace write failed: \(why)"
            case .flushFailed(let why): return "Trace flush failed: \(why)"
            }
        }
    }

    enum Health: Equatable {
        case stopped
        case recording
        case failed(String)
    }

    private(set) var isRecording = false
    private(set) var currentFile: URL?
    /// Successful event writes in this launch (not reset by daily rotation).
    private(set) var eventCount = 0
    private(set) var health: Health = .stopped
    private(set) var lastError: String?

    private var handle: FileHandle?
    private var subscription: AnyCancellable?
    private var syncTimer: Timer?
    private let encoder = JSONEncoder()
    private var currentDay = ""
    private var pendingTailRecoveries: [TraceTailRecovery] = []
    private var lastSyncUptime: TimeInterval = 0
    private static let syncInterval: TimeInterval = 30
    private static let writerFailureJournalName = "trace-writer-failure.json"

    static func tracesDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Dragaway/IntentTraces", isDirectory: true)
    }

    static func ensureTracesDirectory() throws -> URL {
        let dir = tracesDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            throw RecorderError.directoryUnavailable(error.localizedDescription)
        }
    }

    static func prepareForNewStudy() throws {
        let fm = FileManager.default
        let directory = try ensureTracesDirectory()
        let contents = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        let legacy = contents.filter {
            $0.pathExtension.lowercased() == "jsonl"
                || $0.lastPathComponent == writerFailureJournalName
                || $0.lastPathComponent == "ax-probe-results.txt"
        }
        guard !legacy.isEmpty else { return }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let archive = directory.appendingPathComponent(
            "prestudy-\(stamp.string(from: Date()))", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        do {
            for source in legacy {
                try fm.moveItem(at: source,
                                to: archive.appendingPathComponent(source.lastPathComponent))
            }
        } catch {
            // Roll back anything already moved; setup remains stopped and can surface
            // the error instead of starting a mixed-provenance study.
            if let moved = try? fm.contentsOfDirectory(at: archive,
                                                       includingPropertiesForKeys: nil) {
                for source in moved {
                    try? fm.moveItem(at: source,
                                     to: directory.appendingPathComponent(source.lastPathComponent))
                }
            }
            try? fm.removeItem(at: archive)
            throw RecorderError.directoryUnavailable(
                "could not archive pre-study recorder data: \(error.localizedDescription)")
        }
    }

#if THESIS_STUDY_BUILD
    /// Deterministic CLI seam for the only repair the recorder is allowed to make:
    /// finish a valid final JSON object, or discard one incomplete final fragment.
    /// It operates in an isolated temporary directory and never touches live traces.
    static func tailRecoveryCheckForTesting() -> Bool {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("dragaway-tail-check-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }

            let valid = directory.appendingPathComponent("trace-valid.jsonl")
            let incomplete = directory.appendingPathComponent("trace-incomplete.jsonl")
            try Data("{\"header\":{}}\n{\"event\":true}".utf8).write(to: valid)
            try Data("{\"header\":{}}\n{\"event\":".utf8).write(to: incomplete)

            let recoveries = try recoverInterruptedTails(in: directory)
            let journaled = try readRecoveryJournal(in: directory)
            let recoveredValid = try Data(contentsOf: valid)
            let recoveredIncomplete = try Data(contentsOf: incomplete)
            // A torn audit sidecar must never be mistaken for a participant trace and
            // rewritten while it is also being appended to.
            let journalURL = recoveryJournalURL(in: directory)
            let tornJournal = Data("{\"v\":1".utf8)
            try tornJournal.write(to: journalURL)
            let secondPass = try recoverInterruptedTails(in: directory)
            let journalStayedUntouched = try Data(contentsOf: journalURL) == tornJournal

            return recoveries.count == 2 && journaled.count == 2
                && secondPass.isEmpty && journalStayedUntouched
                && recoveredValid == Data("{\"header\":{}}\n{\"event\":true}\n".utf8)
                && recoveredIncomplete == Data("{\"header\":{}}\n".utf8)
        } catch {
            return false
        }
    }
#endif

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static func dayKey(for date: Date) -> String { dayFormatter.string(from: date) }

    /// Compatibility entry point for existing UI calls. Failure remains visible via
    /// `health`/`lastError`, and recording never becomes active on a partial open.
    func start(bus: SignalBus) {
        guard !isRecording else { return }
        do { try startOrThrow(bus: bus) }
        catch {
            // `startOrThrow` already leaves the recorder failed and posts one visible
            // notification. Do not report or journal the same startup failure twice.
        }
    }

    /// Study/restart API: callers can surface or abort on recorder startup failure.
    func startOrThrow(bus: SignalBus) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        // A failed writer may leave a stale handle solely so its close error remains
        // observable. A restart begins from a clean handle and a fresh trace segment.
        subscription = nil
        closeIgnoringErrors()
        lastError = nil
        eventCount = 0
        do {
            let directory = try Self.ensureTracesDirectory()
            let writerFailure = try Self.readWriterFailureJournal(in: directory)
            _ = try Self.recoverInterruptedTails(in: directory)
            // Journal is the durable source of truth and already contains both any
            // prior uncommitted repairs and the ones made immediately above.
            pendingTailRecoveries = try Self.readRecoveryJournal(in: directory)
            try openFile(for: Date(), directory: directory)
            try Self.clearRecoveryJournal(in: directory)
            isRecording = true
            health = .recording

            if let writerFailure {
                let gapSeconds = max(0, MonotonicClock.wallNow - writerFailure.failedWallTime)
                let boundary = SignalEvent.live(
                    kind: .activity,
                    activity: ActivityPayload(state: "capture_failed", seconds: gapSeconds))
                try append(boundary)
                guard let handle else {
                    throw RecorderError.flushFailed("recovered capture boundary has no file handle")
                }
                // The journal remains the source of truth until this exact boundary is
                // durably in the new trace. A failed append/sync therefore retries on
                // the next launch rather than turning the outage into a silent gap.
                try handle.synchronize()
                lastSyncUptime = MonotonicClock.uptimeNow
                try Self.clearWriterFailureJournal(in: directory)
            }

            subscription = bus.events.sink { [weak self] event in self?.write(event) }
            armSyncTimer()
        } catch {
            closeIgnoringErrors()
            fail(error)
            throw error
        }
    }

    func stop() {
        subscription = nil
        syncTimer?.invalidate()
        syncTimer = nil
        let priorFailure: String?
        if case .failed(let message) = health { priorFailure = message }
        else { priorFailure = nil }
        guard isRecording || handle != nil else {
            if priorFailure == nil { health = .stopped }
            return
        }
        var stopError: Error?
        do { try flush() }
        catch { stopError = error }
        do { try handle?.close() }
        catch { if stopError == nil { stopError = error } }
        handle = nil
        currentDay = ""
        lastSyncUptime = 0
        isRecording = false
        if let stopError { fail(stopError) }
        else if let priorFailure { health = .failed(priorFailure) }
        else { health = .stopped }
    }

    /// Flushes without stopping; used immediately before an export snapshot.
    func flush() throws {
        if case .failed(let message) = health {
            throw RecorderError.flushFailed(message)
        }
        guard let handle else {
            if isRecording { throw RecorderError.flushFailed("recording has no open file handle") }
            return
        }
        do { try handle.synchronize() }
        catch {
            let wrapped = RecorderError.flushFailed(error.localizedDescription)
            fail(wrapped)
            throw wrapped
        }
    }

    private func openFile(for date: Date, directory suppliedDirectory: URL? = nil) throws {
        let directory: URL
        if let suppliedDirectory { directory = suppliedDirectory }
        else { directory = try Self.ensureTracesDirectory() }
        let day = Self.dayKey(for: date)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appendingPathComponent("trace-\(stamp.string(from: date)).jsonl")

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecorderError.createFailed(url.path)
        }
        let newHandle: FileHandle
        do { newHandle = try FileHandle(forWritingTo: url) }
        catch { throw RecorderError.openFailed(url.path) }

        do {
            let header = TraceHeader(
                v: 5,
                app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                startedWallTime: MonotonicClock.wallNow,
                startedUptime: MonotonicClock.uptimeNow,
                day: day,
                sessionID: MonotonicClock.sessionID,
                processID: MonotonicClock.processID,
                study: StudyMode.stampFields,
                recoveredTails: pendingTailRecoveries)
            let encoded = try encoder.encode(["header": header]) + Data("\n".utf8)
            try newHandle.write(contentsOf: encoded)
            try newHandle.synchronize()
        } catch {
            try? newHandle.close()
            try? FileManager.default.removeItem(at: url)
            if error is EncodingError {
                throw RecorderError.encodeFailed(error.localizedDescription)
            }
            throw RecorderError.writeFailed(error.localizedDescription)
        }

        // Only retire the old file after the replacement and its header are durable.
        let oldHandle = handle
        handle = newHandle
        currentFile = url
        currentDay = day
        lastSyncUptime = MonotonicClock.uptimeNow
        pendingTailRecoveries.removeAll(keepingCapacity: false)
        if let oldHandle {
            var retirementError: Error?
            do { try oldHandle.synchronize() }
            catch { retirementError = error }
            do { try oldHandle.close() }
            catch { if retirementError == nil { retirementError = error } }
            if let retirementError {
                // New file is valid, but an unsafe rotation boundary is still a recorder
                // failure: do not claim continuous healthy capture.
                throw RecorderError.flushFailed(retirementError.localizedDescription)
            }
        }
    }

    private func write(_ event: SignalEvent) {
        guard isRecording, health == .recording else { return }
        do {
            try append(event)
        } catch {
            fail(error)
            subscription = nil
            closeIgnoringErrors()
        }
    }

    private func append(_ event: SignalEvent) throws {
        let date = Date(timeIntervalSince1970: event.wallTime ?? event.t)
        let day = Self.dayKey(for: date)
        if day != currentDay { try openFile(for: date) }
        guard let handle else { throw RecorderError.writeFailed("missing file handle") }
        let data: Data
        do { data = try encoder.encode(event) + Data("\n".utf8) }
        catch { throw RecorderError.encodeFailed(error.localizedDescription) }
        do {
            try handle.write(contentsOf: data)
            let uptimeNow = MonotonicClock.uptimeNow
            if uptimeNow - lastSyncUptime >= Self.syncInterval {
                try handle.synchronize()
                lastSyncUptime = uptimeNow
            }
        } catch {
            throw RecorderError.writeFailed(error.localizedDescription)
        }
        eventCount += 1
    }

    private func fail(_ error: Error) {
        subscription = nil
        syncTimer?.invalidate()
        syncTimer = nil
        var message = error.localizedDescription
        if StudyMode.isActive {
            do { try Self.persistWriterFailureIfNeeded(for: error) }
            catch {
                message += " · failure-gap journal failed: \(error.localizedDescription)"
            }
        }
        lastError = message
        health = .failed(message)
        isRecording = false
        NotificationCenter.default.post(name: .intentTraceRecorderFailed,
                                        object: self,
                                        userInfo: ["error": message])
    }

    private func closeIgnoringErrors() {
        try? handle?.close()
        handle = nil
        currentDay = ""
        lastSyncUptime = 0
    }

    private func armSyncTimer() {
        syncTimer?.invalidate()
        let timer = Timer(timeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            self?.synchronizePeriodically()
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func synchronizePeriodically() {
        guard isRecording, health == .recording, let handle else { return }
        do {
            try handle.synchronize()
            lastSyncUptime = MonotonicClock.uptimeNow
        } catch {
            let wrapped = RecorderError.flushFailed(error.localizedDescription)
            fail(wrapped)
            closeIgnoringErrors()
        }
    }

    /// A process can die after writing JSON bytes but before writing their trailing
    /// newline. Repair only that final record: valid JSON gets its missing newline;
    /// an incomplete final fragment is truncated. Interior corruption is deliberately
    /// untouched so export validation still fails visibly instead of rewriting data.
    private static func recoverInterruptedTails(in directory: URL) throws -> [TraceTailRecovery] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
            .filter {
                $0.lastPathComponent != "trace-recovery-journal.jsonl"
                    && $0.lastPathComponent.hasPrefix("trace-")
                    && $0.pathExtension == "jsonl"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var recoveries: [TraceTailRecovery] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { continue }
            if let recovery = try recoverInterruptedTail(at: url) {
                recoveries.append(recovery)
            }
        }
        return recoveries
    }

    private static func recoverInterruptedTail(at url: URL) throws -> TraceTailRecovery? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }
        try handle.seek(toOffset: size - 1)
        guard try handle.read(upToCount: 1) != Data([0x0A]) else { return nil }

        let chunkSize: UInt64 = 64 * 1_024
        var cursor = size
        var lineStart: UInt64 = 0
        search: while cursor > 0 {
            let start = cursor > chunkSize ? cursor - chunkSize : 0
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            if let index = chunk.lastIndex(of: 0x0A) {
                lineStart = start + UInt64(chunk.distance(from: chunk.startIndex, to: index)) + 1
                break search
            }
            cursor = start
        }

        try handle.seek(toOffset: lineStart)
        let tail = try handle.readToEnd() ?? Data()
        let action: String
        let recovery: TraceTailRecovery
        if (try? JSONSerialization.jsonObject(with: tail)) is [String: Any] {
            recovery = TraceTailRecovery(file: url.lastPathComponent,
                                         action: "completed_valid_tail_missing_newline",
                                         affectedBytes: size - lineStart,
                                         recoveredWallTime: MonotonicClock.wallNow)
            try appendRecoveryJournal(recovery, in: url.deletingLastPathComponent())
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
            action = "completed_valid_tail_missing_newline"
        } else {
            recovery = TraceTailRecovery(file: url.lastPathComponent,
                                         action: "discarded_incomplete_tail",
                                         affectedBytes: size - lineStart,
                                         recoveredWallTime: MonotonicClock.wallNow)
            try appendRecoveryJournal(recovery, in: url.deletingLastPathComponent())
            try handle.truncate(atOffset: lineStart)
            action = "discarded_incomplete_tail"
        }
        try handle.synchronize()
        return TraceTailRecovery(file: recovery.file, action: action,
                                 affectedBytes: recovery.affectedBytes,
                                 recoveredWallTime: recovery.recoveredWallTime)
    }

    private static func recoveryJournalURL(in directory: URL) -> URL {
        directory.appendingPathComponent("trace-recovery-journal.jsonl")
    }

    /// Journal before mutating the source tail. If opening the next trace fails, the
    /// repair remains durable and will be folded into the next successful v5 header.
    private static func appendRecoveryJournal(_ recovery: TraceTailRecovery,
                                              in directory: URL) throws {
        let url = recoveryJournalURL(in: directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw RecorderError.createFailed(url.path)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(
            TraceRecoveryJournal(v: 1, recovery: recovery)) + Data("\n".utf8))
        try handle.synchronize()
    }

    private static func readRecoveryJournal(in directory: URL) throws -> [TraceTailRecovery] {
        let url = recoveryJournalURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.last == 0x0A, let text = String(data: data, encoding: .utf8) else {
            throw RecorderError.openFailed("invalid recovery journal at \(url.path)")
        }
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            let row = try decoder.decode(TraceRecoveryJournal.self, from: Data($0.utf8))
            guard row.v == 1 else {
                throw RecorderError.openFailed("unsupported recovery journal at \(url.path)")
            }
            return row.recovery
        }
    }

    private static func clearRecoveryJournal(in directory: URL) throws {
        let url = recoveryJournalURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func writerFailureJournalURL(in directory: URL) -> URL {
        directory.appendingPathComponent(writerFailureJournalName)
    }

    /// First failure wins until a recovered boundary is durable. Repeated write or
    /// flush callbacks must not move the beginning of the analytically missing span.
    private static func persistWriterFailureIfNeeded(for error: Error) throws {
        let directory = try ensureTracesDirectory()
        let url = writerFailureJournalURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try readWriterFailureJournal(in: directory) // validate; never overwrite
            return
        }

        let record = TraceWriterFailureJournal(
            v: 1,
            failedWallTime: MonotonicClock.wallNow,
            failedUptime: MonotonicClock.uptimeNow,
            sessionID: MonotonicClock.sessionID,
            processID: MonotonicClock.processID,
            kind: writerFailureKind(error))
        let data = try JSONEncoder().encode(record) + Data("\n".utf8)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func readWriterFailureJournal(in directory: URL) throws
        -> TraceWriterFailureJournal? {
        let url = writerFailureJournalURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.last == 0x0A,
              let record = try? JSONDecoder().decode(TraceWriterFailureJournal.self,
                                                     from: data),
              record.v == 1,
              record.failedWallTime.isFinite, record.failedWallTime > 0,
              record.failedUptime.isFinite, record.failedUptime >= 0,
              UUID(uuidString: record.sessionID) != nil,
              record.processID > 0,
              ["directory_unavailable", "create_failed", "open_failed", "encode_failed",
               "write_failed", "flush_failed", "io_failure"].contains(record.kind) else {
            throw RecorderError.openFailed("invalid writer-failure journal at \(url.path)")
        }
        return record
    }

    private static func clearWriterFailureJournal(in directory: URL) throws {
        let url = writerFailureJournalURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func writerFailureKind(_ error: Error) -> String {
        guard let recorderError = error as? RecorderError else { return "io_failure" }
        switch recorderError {
        case .directoryUnavailable: return "directory_unavailable"
        case .alreadyRecording: return "io_failure"
        case .createFailed: return "create_failed"
        case .openFailed: return "open_failed"
        case .encodeFailed: return "encode_failed"
        case .writeFailed: return "write_failed"
        case .flushFailed: return "flush_failed"
        }
    }
}

private struct TraceHeader: Codable {
    let v: Int
    let app: String
    let startedWallTime: TimeInterval
    let startedUptime: TimeInterval
    let day: String
    let sessionID: String
    let processID: Int32
    let study: [String: String]
    let recoveredTails: [TraceTailRecovery]
}
