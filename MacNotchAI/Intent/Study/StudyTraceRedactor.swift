import Foundation

/// Content-free audit row exported alongside the retained study artefacts. It records
/// only that a participant removed a recent interval; no reason, prompt, file name,
/// application, action, or deleted payload is retained.
struct StudyRedactionReceipt: Codable, Equatable {
    let schemaVersion: Int
    let redactionID: String
    let requestedWallTime: TimeInterval
    let cutoffWallTime: TimeInterval
    let durationSeconds: TimeInterval
    let participant: String
    let consentVersion: Int
    let consentAcceptedAt: TimeInterval
}

// THESIS — participant-controlled deletion of one recent suffix of the active cohort.
// A durable request is written before any source byte changes. The transformation is
// idempotent, so a crash or disk error leaves a visible pending request that is safely
// completed before capture/export resumes.
enum StudyTraceRedactor {

    static let minimumDuration: TimeInterval = 5 * 60
    static let maximumDuration: TimeInterval = 4 * 60 * 60
    static let durationStep: TimeInterval = 5 * 60
    static let receiptFileName = "redaction-log.jsonl"

    private static let pendingFileName = "redaction-pending.json"
    private static let writerFailureFileName = "trace-writer-failure.json"

    struct Summary: Equatable {
        let redactionID: String
        let cutoffWallTime: TimeInterval
        let durationSeconds: TimeInterval
    }

    enum RedactionError: LocalizedError {
        case unsupportedDuration
        case missingDeployment
        case invalidPendingRequest
        case invalidSource(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedDuration:
                return "Choose a duration from 5 minutes through 4 hours in 5-minute steps."
            case .missingDeployment:
                return "No valid study deployment is available for this recording."
            case .invalidPendingRequest:
                return "The pending trace-erasure request is invalid. Recording remains stopped."
            case .invalidSource(let name):
                return "Trace erasure stopped because \(name) is not a valid study artefact."
            case .writeFailed(let why):
                return "Trace erasure could not be completed: \(why)"
            }
        }
    }

    private enum Mutation {
        case replace(URL, Data)
        case remove(URL)
    }

    private struct AffordanceIndex: Codable {
        let wall: TimeInterval
        let interactionID: String?
    }

    private struct TraceHeaderIndex: Codable {
        struct Header: Codable { let startedWallTime: TimeInterval }
        let header: Header
    }

    private struct TraceRecoveryIndex: Codable {
        struct Recovery: Codable {
            let file: String
            let recoveredWallTime: TimeInterval
        }
        let recovery: Recovery
    }

    private struct AffordanceRecoveryIndex: Codable {
        let recoveredWallTime: TimeInterval
    }

    private struct WriterFailureIndex: Codable {
        let failedWallTime: TimeInterval
    }

    static var hasPendingRequest: Bool {
        FileManager.default.fileExists(atPath: pendingURL().path)
    }

    static func isSupportedDuration(_ seconds: TimeInterval) -> Bool {
        guard seconds.isFinite,
              (minimumDuration...maximumDuration).contains(seconds) else { return false }
        return abs(seconds.truncatingRemainder(dividingBy: durationStep)) < 0.001
    }

    static func isValidReceipt(_ receipt: StudyRedactionReceipt) -> Bool {
        receipt.schemaVersion == 1
            && UUID(uuidString: receipt.redactionID) != nil
            && receipt.requestedWallTime.isFinite && receipt.requestedWallTime > 0
            && receipt.cutoffWallTime.isFinite && receipt.cutoffWallTime > 0
            && isSupportedDuration(receipt.durationSeconds)
            && abs((receipt.requestedWallTime - receipt.cutoffWallTime)
                   - receipt.durationSeconds) < 0.001
            && !receipt.participant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && receipt.consentVersion > 0
            && receipt.consentAcceptedAt.isFinite && receipt.consentAcceptedAt > 0
    }

    /// A pre-existing request always wins. Retrying the UI therefore completes the
    /// original privacy operation instead of silently replacing it with a new cutoff.
    static func eraseRecent(durationSeconds: TimeInterval,
                            requestedAt: TimeInterval = MonotonicClock.wallNow) throws -> Summary {
        if let pending = try loadPendingIfPresent() {
            return try apply(pending)
        }
        guard isSupportedDuration(durationSeconds) else {
            throw RedactionError.unsupportedDuration
        }
        guard let deployment = StudyMode.deploymentSnapshot else {
            throw RedactionError.missingDeployment
        }
        let request = StudyRedactionReceipt(
            schemaVersion: 1,
            redactionID: UUID().uuidString,
            requestedWallTime: requestedAt,
            cutoffWallTime: requestedAt - durationSeconds,
            durationSeconds: durationSeconds,
            participant: deployment.participantID,
            consentVersion: deployment.consentVersion,
            consentAcceptedAt: deployment.consentAcceptedAt)
        guard isValidReceipt(request) else { throw RedactionError.invalidPendingRequest }
        try persistPending(request)
        return try apply(request)
    }

    @discardableResult
    static func resumePendingIfNeeded() throws -> Summary? {
        guard let pending = try loadPendingIfPresent() else { return nil }
        return try apply(pending)
    }

    private static func apply(_ request: StudyRedactionReceipt) throws -> Summary {
        guard isValidReceipt(request) else { throw RedactionError.invalidPendingRequest }
        let fm = FileManager.default
        let directory = try TraceRecorder.ensureTracesDirectory()
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])

        // Validate the complete current cohort before planning any mutation. A malformed
        // source remains untouched and the durable request forces a visible retry.
        for source in contents where source.pathExtension.lowercased() == "jsonl" {
            do { try StudyExporter.validateJSONLForRedaction(source) }
            catch { throw RedactionError.invalidSource(source.lastPathComponent) }
        }

        let traceFiles = contents.filter { isTraceFile($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var mutations: [Mutation] = []
        var removedTraceNames = Set<String>()

        for source in traceFiles {
            if let retained = try filteredTrace(source, cutoff: request.cutoffWallTime) {
                try validateReplacement(retained, named: source.lastPathComponent)
                if retained != (try Data(contentsOf: source)) {
                    mutations.append(.replace(source, retained))
                }
            } else {
                removedTraceNames.insert(source.lastPathComponent)
                mutations.append(.remove(source))
            }
        }

        if let source = contents.first(where: { $0.lastPathComponent == "affordance-log.jsonl" }) {
            if let retained = try filteredAffordances(source, cutoff: request.cutoffWallTime) {
                try validateReplacement(retained, named: source.lastPathComponent)
                if retained != (try Data(contentsOf: source)) {
                    mutations.append(.replace(source, retained))
                }
            } else {
                mutations.append(.remove(source))
            }
        }

        if let source = contents.first(where: {
            $0.lastPathComponent == "trace-recovery-journal.jsonl"
        }) {
            if let retained = try filteredTraceRecovery(
                source, cutoff: request.cutoffWallTime,
                removedTraceNames: removedTraceNames
            ) {
                try validateReplacement(retained, named: source.lastPathComponent)
                if retained != (try Data(contentsOf: source)) {
                    mutations.append(.replace(source, retained))
                }
            } else {
                mutations.append(.remove(source))
            }
        }

        if let source = contents.first(where: {
            $0.lastPathComponent == "affordance-recovery-journal.jsonl"
        }) {
            if let retained = try filteredAffordanceRecovery(
                source, cutoff: request.cutoffWallTime
            ) {
                try validateReplacement(retained, named: source.lastPathComponent)
                if retained != (try Data(contentsOf: source)) {
                    mutations.append(.replace(source, retained))
                }
            } else {
                mutations.append(.remove(source))
            }
        }

        if let source = contents.first(where: { $0.lastPathComponent == writerFailureFileName }) {
            let index: WriterFailureIndex
            do { index = try JSONDecoder().decode(WriterFailureIndex.self,
                                                   from: Data(contentsOf: source)) }
            catch { throw RedactionError.invalidSource(source.lastPathComponent) }
            if index.failedWallTime >= request.cutoffWallTime {
                mutations.append(.remove(source))
            }
        }

        let receiptURL = directory.appendingPathComponent(receiptFileName)
        let receiptData = try appendingReceipt(request, to: receiptURL)
        try validateReplacement(receiptData, named: receiptFileName)
        mutations.append(.replace(receiptURL, receiptData))

        // Every replacement has already passed the same typed validator used by export.
        // The pending request remains durable across every individual atomic replace.
        do {
            for mutation in mutations {
                switch mutation {
                case .replace(let url, let data):
                    try data.write(to: url, options: [.atomic])
                    guard try Data(contentsOf: url) == data else {
                        throw RedactionError.writeFailed(
                            "verification failed for \(url.lastPathComponent)")
                    }
                case .remove(let url):
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                }
            }

            let finalContents = try fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            for source in finalContents where source.pathExtension.lowercased() == "jsonl" {
                try StudyExporter.validateJSONLForRedaction(source)
            }
            guard try receiptIDs(in: receiptURL).contains(request.redactionID) else {
                throw RedactionError.writeFailed("redaction receipt was not persisted")
            }
            try fm.removeItem(at: pendingURL())
        } catch let error as RedactionError {
            throw error
        } catch {
            throw RedactionError.writeFailed(error.localizedDescription)
        }

        return Summary(redactionID: request.redactionID,
                       cutoffWallTime: request.cutoffWallTime,
                       durationSeconds: request.durationSeconds)
    }

    private static func filteredTrace(_ url: URL,
                                      cutoff: TimeInterval) throws -> Data? {
        let lines = try jsonLines(at: url)
        guard let header = lines.first else {
            throw RedactionError.invalidSource(url.lastPathComponent)
        }
        let decoder = JSONDecoder()
        guard let headerIndex = try? decoder.decode(TraceHeaderIndex.self, from: header) else {
            throw RedactionError.invalidSource(url.lastPathComponent)
        }
        if headerIndex.header.startedWallTime >= cutoff { return nil }
        var retained: [Data] = [header]
        var erasingSuffix = false
        for line in lines.dropFirst() {
            guard let event = try? decoder.decode(SignalEvent.self, from: line),
                  let wall = event.wallTime else {
                throw RedactionError.invalidSource(url.lastPathComponent)
            }
            if wall >= cutoff { erasingSuffix = true }
            if !erasingSuffix { retained.append(line) }
        }
        return retained.count > 1 ? jsonl(retained) : nil
    }

    private static func filteredAffordances(_ url: URL,
                                            cutoff: TimeInterval) throws -> Data? {
        let lines = try jsonLines(at: url)
        let decoder = JSONDecoder()
        let indexed: [(line: Data, index: AffordanceIndex)] = try lines.map { line in
            guard let index = try? decoder.decode(AffordanceIndex.self, from: line) else {
                throw RedactionError.invalidSource(url.lastPathComponent)
            }
            return (line, index)
        }
        guard let suffixStart = indexed.firstIndex(where: { $0.index.wall >= cutoff }) else {
            return jsonl(indexed.map(\.line))
        }
        let affectedInteractions = Set(indexed[suffixStart...].compactMap {
            $0.index.interactionID
        })
        let retained = indexed[..<suffixStart].compactMap { item -> Data? in
            if let id = item.index.interactionID, affectedInteractions.contains(id) {
                return nil
            }
            return item.line
        }
        return retained.isEmpty ? nil : jsonl(retained)
    }

    private static func filteredTraceRecovery(
        _ url: URL, cutoff: TimeInterval, removedTraceNames: Set<String>
    ) throws -> Data? {
        let decoder = JSONDecoder()
        let retained = try jsonLines(at: url).filter { line in
            guard let index = try? decoder.decode(TraceRecoveryIndex.self, from: line) else {
                throw RedactionError.invalidSource(url.lastPathComponent)
            }
            return index.recovery.recoveredWallTime < cutoff
                && !removedTraceNames.contains(index.recovery.file)
        }
        return retained.isEmpty ? nil : jsonl(retained)
    }

    private static func filteredAffordanceRecovery(
        _ url: URL, cutoff: TimeInterval
    ) throws -> Data? {
        let decoder = JSONDecoder()
        let retained = try jsonLines(at: url).filter { line in
            guard let index = try? decoder.decode(AffordanceRecoveryIndex.self, from: line) else {
                throw RedactionError.invalidSource(url.lastPathComponent)
            }
            return index.recoveredWallTime < cutoff
        }
        return retained.isEmpty ? nil : jsonl(retained)
    }

    private static func appendingReceipt(_ receipt: StudyRedactionReceipt,
                                         to url: URL) throws -> Data {
        var receipts: [StudyRedactionReceipt] = []
        if FileManager.default.fileExists(atPath: url.path) {
            receipts = try jsonLines(at: url).map {
                try JSONDecoder().decode(StudyRedactionReceipt.self, from: $0)
            }
        }
        if !receipts.contains(where: { $0.redactionID == receipt.redactionID }) {
            receipts.append(receipt)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try jsonl(receipts.map { try encoder.encode($0) })
    }

    private static func receiptIDs(in url: URL) throws -> Set<String> {
        Set(try jsonLines(at: url).map {
            try JSONDecoder().decode(StudyRedactionReceipt.self, from: $0).redactionID
        })
    }

    private static func validateReplacement(_ data: Data, named name: String) throws {
        do { try StudyExporter.validateJSONLForRedaction(data, named: name) }
        catch { throw RedactionError.invalidSource(name) }
    }

    private static func jsonLines(at url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.last == 0x0A,
              String(data: data, encoding: .utf8) != nil else {
            throw RedactionError.invalidSource(url.lastPathComponent)
        }
        return [UInt8](data).split(separator: 0x0A,
                                  omittingEmptySubsequences: true).map {
            Data(Array($0))
        }
    }

    private static func jsonl(_ lines: [Data]) -> Data {
        var output = Data()
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        return output
    }

    private static func isTraceFile(_ name: String) -> Bool {
        name.hasPrefix("trace-") && name.hasSuffix(".jsonl")
            && name != "trace-recovery-journal.jsonl"
    }

    private static func pendingURL() -> URL {
        TraceRecorder.tracesDirectory().appendingPathComponent(pendingFileName)
    }

    private static func loadPendingIfPresent() throws -> StudyRedactionReceipt? {
        let url = pendingURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request: StudyRedactionReceipt
        do { request = try JSONDecoder().decode(StudyRedactionReceipt.self,
                                                from: Data(contentsOf: url)) }
        catch { throw RedactionError.invalidPendingRequest }
        guard isValidReceipt(request) else { throw RedactionError.invalidPendingRequest }
        return request
    }

    private static func persistPending(_ request: StudyRedactionReceipt) throws {
        let directory = try TraceRecorder.ensureTracesDirectory()
        let url = directory.appendingPathComponent(pendingFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        do {
            try data.write(to: url, options: [.atomic])
            guard try Data(contentsOf: url) == data else {
                throw RedactionError.writeFailed("pending request verification failed")
            }
        } catch let error as RedactionError {
            throw error
        } catch {
            throw RedactionError.writeFailed(error.localizedDescription)
        }
    }

#if THESIS_STUDY_BUILD
    struct RedactionCheckResult {
        let pass: Bool
        let detail: String
    }

    /// Pure temporary-fixture seam. It never opens the live trace directory and proves
    /// the bounded slider contract, suffix filtering, whole-interaction deletion,
    /// malformed-row rejection, and duplicate-retry receipt idempotency.
    static func redactionCheckForTesting() -> RedactionCheckResult {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(
            "dragaway-redaction-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }

            let session = "11111111-1111-4111-8111-111111111111"
            func event(_ wall: Double, uptime: Double) -> Data {
                let object: [String: Any] = [
                    "t": uptime, "kind": "activity", "wallTime": wall,
                    "uptime": uptime, "sessionID": session, "processID": 42,
                    "activity": ["state": "active", "seconds": 0],
                ]
                return try! JSONSerialization.data(withJSONObject: object,
                                                    options: [.sortedKeys])
            }

            let traceURL = directory.appendingPathComponent("trace-fixture.jsonl")
            try jsonl([Data("{\"header\":{\"startedWallTime\":80}}".utf8),
                       event(90, uptime: 10),
                       event(110, uptime: 20)]).write(to: traceURL)
            let filteredTraceData = try filteredTrace(traceURL, cutoff: 100)
            let traceLines = filteredTraceData.map {
                [UInt8]($0).split(separator: 0x0A, omittingEmptySubsequences: true)
            } ?? []

            let affordanceURL = directory.appendingPathComponent("affordance-log.jsonl")
            let affordanceLines = [
                Data("{\"wall\":90,\"interactionID\":\"affected\"}".utf8),
                Data("{\"wall\":95,\"interactionID\":\"retained\"}".utf8),
                Data("{\"wall\":110,\"interactionID\":\"affected\"}".utf8),
            ]
            try jsonl(affordanceLines).write(to: affordanceURL)
            let filteredAffordanceData = try filteredAffordances(
                affordanceURL, cutoff: 100)
            let filteredAffordanceText = filteredAffordanceData.flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""

            let malformedURL = directory.appendingPathComponent("malformed.jsonl")
            try Data("{}\n".utf8).write(to: malformedURL)
            var malformedRejected = false
            do { _ = try filteredAffordances(malformedURL, cutoff: 100) }
            catch { malformedRejected = true }

            let receipt = StudyRedactionReceipt(
                schemaVersion: 1,
                redactionID: "22222222-2222-4222-8222-222222222222",
                requestedWallTime: 20_000,
                cutoffWallTime: 19_700,
                durationSeconds: minimumDuration,
                participant: "P-test",
                consentVersion: 3,
                consentAcceptedAt: 10_000)
            let receiptURL = directory.appendingPathComponent(receiptFileName)
            let once = try appendingReceipt(receipt, to: receiptURL)
            try once.write(to: receiptURL)
            let twice = try appendingReceipt(receipt, to: receiptURL)
            let receiptLines = [UInt8](twice).split(
                separator: 0x0A, omittingEmptySubsequences: true).count
            let receiptValidated: Bool
            do {
                try StudyExporter.validateJSONLForRedaction(twice, named: receiptFileName)
                receiptValidated = true
            } catch {
                receiptValidated = false
            }

            let bounds = isSupportedDuration(minimumDuration)
                && isSupportedDuration(maximumDuration)
                && !isSupportedDuration(minimumDuration - 1)
                && !isSupportedDuration(maximumDuration + durationStep)
            let trace = traceLines.count == 2
            let interaction = filteredAffordanceText.contains("retained")
                && !filteredAffordanceText.contains("affected")
            let receiptOK = isValidReceipt(receipt) && receiptValidated
                && receiptLines == 1
            let pass = bounds && trace && interaction && malformedRejected && receiptOK
            return RedactionCheckResult(
                pass: pass,
                detail: "bounds=\(bounds), trace=\(trace), interaction=\(interaction), "
                    + "malformed=\(malformedRejected), receipt=\(receiptOK)")
        } catch {
            return RedactionCheckResult(pass: false,
                                        detail: "fixture threw: \(error.localizedDescription)")
        }
    }
#endif
}
