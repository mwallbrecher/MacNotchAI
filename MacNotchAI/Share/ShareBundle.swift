import Darwin
import Foundation

/// A decrypted sharing snapshot.
///
/// Single-file snapshots keep the original v2 wire format. Multi-file snapshots use v3, whose
/// metadata contains an ordered filename/length table followed by the concatenated raw file bytes.
/// `ShareBundle` deliberately is not `Codable`: the only wire representations are the bounded,
/// canonical binary envelopes implemented below.
nonisolated struct ShareBundle: Sendable {

    nonisolated static let legacyVersion = 2
    nonisolated static let multiFileVersion = 3
    nonisolated static let version = multiFileVersion

    nonisolated static let v2EnvelopeMagic = Data([0x44, 0x52, 0x41, 0x47, 0x53, 0x48, 0x52, 0x32])
    nonisolated static let v3EnvelopeMagic = Data([0x44, 0x52, 0x41, 0x47, 0x53, 0x48, 0x52, 0x33])
    nonisolated static let envelopeHeaderBytes = v2EnvelopeMagic.count + MemoryLayout<UInt32>.size

    /// File bytes are bounded in aggregate, not per file, so enabling five files does not enlarge
    /// the existing relay/storage contract.
    nonisolated static let maxFileBytes = 25 * 1_024 * 1_024
    nonisolated static let maxMetadataBytes = 2 * 1_024 * 1_024
    nonisolated static let maxPlaintextBytes = envelopeHeaderBytes + maxMetadataBytes + maxFileBytes
    nonisolated static let maxFiles = 5
    nonisolated static let maxTurns = 100
    nonisolated static let maxFileNameBytes = 255
    nonisolated static let maxActionBytes = 256
    nonisolated static let maxPromptBytes = 16 * 1_024
    nonisolated static let maxResultBytes = 128 * 1_024

    nonisolated struct FilePayload: Equatable, Sendable {
        let fileName: String
        let fileData: Data
    }

    let v: Int
    let files: [FilePayload]
    let turns: [Turn]
    let exposedAt: Date

    /// Compatibility accessors for the deliberately single-file v2 call sites and smoke fixtures.
    nonisolated var fileName: String { files.first?.fileName ?? "" }
    nonisolated var fileData: Data { files.first?.fileData ?? Data() }

    /// Construct a legacy-compatible single-file bundle.
    nonisolated init(
        v: Int = ShareBundle.legacyVersion,
        fileName: String,
        fileData: Data,
        turns: [Turn],
        exposedAt: Date
    ) {
        self.v = v
        files = [FilePayload(fileName: fileName, fileData: fileData)]
        self.turns = turns
        self.exposedAt = exposedAt
    }

    /// Construct a v3 multi-file bundle. v3 intentionally represents only 2–5 files; one file is
    /// encoded as v2 so legacy recipients remain compatible with new single-file shares.
    nonisolated init(
        files: [FilePayload],
        turns: [Turn],
        exposedAt: Date,
        v: Int = ShareBundle.multiFileVersion
    ) {
        self.v = v
        self.files = files
        self.turns = turns
        self.exposedAt = exposedAt
    }

    nonisolated struct Turn: Codable, Equatable, Sendable {
        let actionRaw: String
        let promptTitle: String
        let resultText: String
        let date: Date
    }

    nonisolated enum BundleError: LocalizedError, Equatable {
        case unsupportedVersion
        case invalidEnvelope
        case invalidMetadata
        case metadataTooLarge
        case fileTooLarge
        case invalidFileCount
        case notRegularFile
        case duplicateFileName
        case tooManyTurns
        case invalidFileName
        case invalidTurn
        case fileReadFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                return "This shared session uses an unsupported format version."
            case .invalidEnvelope, .invalidMetadata:
                return "The shared session is damaged or malformed."
            case .metadataTooLarge:
                return "The shared session history is too large."
            case .fileTooLarge:
                let limit = ByteCountFormatter.string(
                    fromByteCount: Int64(ShareBundle.maxFileBytes), countStyle: .file
                )
                return "These files are too large to share together (combined limit \(limit))."
            case .invalidFileCount:
                return "Session Sharing supports between one and five files."
            case .notRegularFile:
                return "Only regular files can be shared. Folders and symbolic links are not supported."
            case .duplicateFileName:
                return "Two shared files have the same filename. Rename one of them and try again."
            case .tooManyTurns:
                return "This session contains too many conversation turns to share safely."
            case .invalidFileName:
                return "A shared file has an invalid or oversized name."
            case .invalidTurn:
                return "The shared conversation contains an invalid or oversized turn."
            case .fileReadFailed:
                return "A file could not be read safely."
            }
        }
    }

    nonisolated static func supports(version: Int) -> Bool {
        version == legacyVersion || version == multiFileVersion
    }

    /// Human-readable aggregate file size for sender disclosure UI.
    nonisolated var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalFileBytes), countStyle: .file)
    }

    nonisolated var totalFileBytes: Int {
        files.reduce(0) { partial, file in partial + file.fileData.count }
    }

    // MARK: - Bounded file loading

    nonisolated static func load(
        from fileURL: URL,
        turns: [Turn],
        exposedAt: Date = Date()
    ) throws -> ShareBundle {
        try load(from: [fileURL], turns: turns, exposedAt: exposedAt)
    }

    /// Opens every input without following its final symlink. The aggregate bound is checked from
    /// `fstat` before allocation and again while reading, covering files that grow concurrently.
    nonisolated static func load(
        from fileURLs: [URL],
        turns: [Turn],
        exposedAt: Date = Date()
    ) throws -> ShareBundle {
        guard (1...maxFiles).contains(fileURLs.count) else { throw BundleError.invalidFileCount }

        var remainingBytes = maxFileBytes
        var loaded: [FilePayload] = []
        loaded.reserveCapacity(fileURLs.count)
        for fileURL in fileURLs {
            let file = try loadFile(from: fileURL, maximumBytes: remainingBytes)
            remainingBytes -= file.fileData.count
            loaded.append(file)
        }

        let bundle: ShareBundle
        if let only = loaded.first, loaded.count == 1 {
            bundle = ShareBundle(
                fileName: only.fileName, fileData: only.fileData,
                turns: turns, exposedAt: exposedAt
            )
        } else {
            bundle = ShareBundle(files: loaded, turns: turns, exposedAt: exposedAt)
        }
        try bundle.validate()
        return bundle
    }

    private nonisolated static func loadFile(
        from fileURL: URL,
        maximumBytes: Int
    ) throws -> FilePayload {
        guard fileURL.isFileURL else { throw BundleError.notRegularFile }

        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw BundleError.notRegularFile }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw BundleError.notRegularFile
        }
        guard info.st_size >= 0, info.st_size <= Int64(maximumBytes) else {
            throw BundleError.fileTooLarge
        }

        var bytes = Data()
        bytes.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BundleError.fileReadFailed
            }
            guard bytes.count <= maximumBytes - count else { throw BundleError.fileTooLarge }
            bytes.append(contentsOf: buffer[0..<count])
        }
        return FilePayload(fileName: fileURL.lastPathComponent, fileData: bytes)
    }

    // MARK: - Binary envelopes

    nonisolated func encodeEnvelope() throws -> Data {
        try validate()
        switch v {
        case Self.legacyVersion:
            return try encodeV2Envelope()
        case Self.multiFileVersion:
            return try encodeV3Envelope()
        default:
            throw BundleError.unsupportedVersion
        }
    }

    /// Detects the authenticated inner format from its magic. The caller additionally binds `v`
    /// to the AES-GCM descriptor after decryption, so a relay cannot swap version metadata.
    nonisolated static func decodeEnvelope(_ envelope: Data) throws -> ShareBundle {
        guard envelope.count >= envelopeHeaderBytes, envelope.count <= maxPlaintextBytes else {
            throw BundleError.invalidEnvelope
        }
        if envelope.prefix(v2EnvelopeMagic.count).elementsEqual(v2EnvelopeMagic) {
            return try decodeV2Envelope(envelope)
        }
        if envelope.prefix(v3EnvelopeMagic.count).elementsEqual(v3EnvelopeMagic) {
            return try decodeV3Envelope(envelope)
        }
        throw BundleError.invalidEnvelope
    }

    private nonisolated func encodeV2Envelope() throws -> Data {
        guard files.count == 1, let file = files.first else { throw BundleError.invalidFileCount }
        let metadataData = try Self.encodeMetadata(V2Metadata(bundle: self, file: file))
        return try Self.assembleEnvelope(
            magic: Self.v2EnvelopeMagic,
            metadata: metadataData,
            payloads: [file.fileData]
        )
    }

    private nonisolated func encodeV3Envelope() throws -> Data {
        let metadataData = try Self.encodeMetadata(V3Metadata(bundle: self))
        return try Self.assembleEnvelope(
            magic: Self.v3EnvelopeMagic,
            metadata: metadataData,
            payloads: files.map(\.fileData)
        )
    }

    private nonisolated static func assembleEnvelope(
        magic: Data,
        metadata: Data,
        payloads: [Data]
    ) throws -> Data {
        guard metadata.count <= maxMetadataBytes else { throw BundleError.metadataTooLarge }
        var total = envelopeHeaderBytes
        for count in [metadata.count] + payloads.map(\.count) {
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw BundleError.invalidEnvelope }
            total = next
        }
        guard total <= maxPlaintextBytes else { throw BundleError.invalidEnvelope }

        var envelope = Data(capacity: total)
        envelope.append(magic)
        let length = UInt32(metadata.count).bigEndian
        withUnsafeBytes(of: length) { envelope.append(contentsOf: $0) }
        envelope.append(metadata)
        for payload in payloads { envelope.append(payload) }
        return envelope
    }

    private nonisolated static func envelopeSections(
        _ envelope: Data,
        magic: Data
    ) throws -> (metadata: Data, payloadStart: Data.Index) {
        guard envelope.count >= envelopeHeaderBytes,
              envelope.count <= maxPlaintextBytes,
              envelope.prefix(magic.count).elementsEqual(magic) else {
            throw BundleError.invalidEnvelope
        }

        let start = envelope.startIndex
        let magicEnd = envelope.index(start, offsetBy: magic.count)
        let lengthEnd = envelope.index(magicEnd, offsetBy: MemoryLayout<UInt32>.size)
        let metadataLength = envelope[magicEnd..<lengthEnd].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard metadataLength > 0, metadataLength <= UInt32(maxMetadataBytes) else {
            throw BundleError.metadataTooLarge
        }
        let (metadataEndOffset, overflow) = envelopeHeaderBytes
            .addingReportingOverflow(Int(metadataLength))
        guard !overflow, metadataEndOffset <= envelope.count else { throw BundleError.invalidEnvelope }

        let metadataEnd = envelope.index(lengthEnd, offsetBy: Int(metadataLength))
        return (Data(envelope[lengthEnd..<metadataEnd]), metadataEnd)
    }

    private nonisolated static func decodeV2Envelope(_ envelope: Data) throws -> ShareBundle {
        let sections = try envelopeSections(envelope, magic: v2EnvelopeMagic)
        let metadata: V2Metadata = try decodeMetadata(sections.metadata)
        try metadata.validate()
        guard envelope.distance(from: sections.payloadStart, to: envelope.endIndex)
                == metadata.fileLength else {
            throw BundleError.invalidEnvelope
        }
        let bundle = ShareBundle(
            v: metadata.v,
            fileName: metadata.fileName,
            fileData: Data(envelope[sections.payloadStart..<envelope.endIndex]),
            turns: metadata.turns,
            exposedAt: metadata.exposedAt
        )
        try bundle.validate()
        return bundle
    }

    private nonisolated static func decodeV3Envelope(_ envelope: Data) throws -> ShareBundle {
        let sections = try envelopeSections(envelope, magic: v3EnvelopeMagic)
        let metadata: V3Metadata = try decodeMetadata(sections.metadata)
        try metadata.validate()

        let totalLength = try checkedTotalLength(metadata.files.map(\.fileLength))
        guard envelope.distance(from: sections.payloadStart, to: envelope.endIndex) == totalLength else {
            throw BundleError.invalidEnvelope
        }

        var cursor = sections.payloadStart
        var files: [FilePayload] = []
        files.reserveCapacity(metadata.files.count)
        for file in metadata.files {
            let end = envelope.index(cursor, offsetBy: file.fileLength)
            files.append(FilePayload(
                fileName: file.fileName,
                fileData: Data(envelope[cursor..<end])
            ))
            cursor = end
        }
        guard cursor == envelope.endIndex else { throw BundleError.invalidEnvelope }

        let bundle = ShareBundle(
            files: files,
            turns: metadata.turns,
            exposedAt: metadata.exposedAt,
            v: metadata.v
        )
        try bundle.validate()
        return bundle
    }

    nonisolated func validate() throws {
        guard Self.supports(version: v) else { throw BundleError.unsupportedVersion }
        if v == Self.legacyVersion {
            guard files.count == 1 else { throw BundleError.invalidFileCount }
        } else {
            guard (2...Self.maxFiles).contains(files.count) else { throw BundleError.invalidFileCount }
        }

        let normalizedNames = files.map { Self.normalizedFileNameKey($0.fileName) }
        guard Set(normalizedNames).count == normalizedNames.count else {
            throw BundleError.duplicateFileName
        }
        for file in files {
            guard Self.isValidFileName(file.fileName) else { throw BundleError.invalidFileName }
        }
        guard try Self.checkedTotalLength(files.map { $0.fileData.count }) <= Self.maxFileBytes else {
            throw BundleError.fileTooLarge
        }
        try Self.validateTurns(turns, exposedAt: exposedAt)
    }

    // MARK: - Canonical metadata

    private nonisolated struct V2Metadata: Codable, Sendable {
        let v: Int
        let fileName: String
        let fileLength: Int
        let turns: [Turn]
        let exposedAt: Date

        nonisolated init(bundle: ShareBundle, file: FilePayload) {
            v = bundle.v
            fileName = file.fileName
            fileLength = file.fileData.count
            turns = bundle.turns
            exposedAt = bundle.exposedAt
        }

        nonisolated func validate() throws {
            guard v == ShareBundle.legacyVersion else { throw BundleError.unsupportedVersion }
            guard ShareBundle.isValidFileName(fileName) else { throw BundleError.invalidFileName }
            guard fileLength >= 0, fileLength <= ShareBundle.maxFileBytes else {
                throw BundleError.fileTooLarge
            }
            try ShareBundle.validateTurns(turns, exposedAt: exposedAt)
        }
    }

    private nonisolated struct V3FileMetadata: Codable, Sendable {
        let fileName: String
        let fileLength: Int
    }

    private nonisolated struct V3Metadata: Codable, Sendable {
        let v: Int
        let files: [V3FileMetadata]
        let turns: [Turn]
        let exposedAt: Date

        nonisolated init(bundle: ShareBundle) {
            v = bundle.v
            files = bundle.files.map {
                V3FileMetadata(fileName: $0.fileName, fileLength: $0.fileData.count)
            }
            turns = bundle.turns
            exposedAt = bundle.exposedAt
        }

        nonisolated func validate() throws {
            guard v == ShareBundle.multiFileVersion else { throw BundleError.unsupportedVersion }
            guard (2...ShareBundle.maxFiles).contains(files.count) else {
                throw BundleError.invalidFileCount
            }
            let normalizedNames = files.map { ShareBundle.normalizedFileNameKey($0.fileName) }
            guard Set(normalizedNames).count == normalizedNames.count else {
                throw BundleError.duplicateFileName
            }
            for file in files {
                guard ShareBundle.isValidFileName(file.fileName) else {
                    throw BundleError.invalidFileName
                }
                guard file.fileLength >= 0 else { throw BundleError.invalidMetadata }
            }
            guard try ShareBundle.checkedTotalLength(files.map(\.fileLength))
                    <= ShareBundle.maxFileBytes else {
                throw BundleError.fileTooLarge
            }
            try ShareBundle.validateTurns(turns, exposedAt: exposedAt)
        }
    }

    private nonisolated static func encodeMetadata<T: Encodable>(_ metadata: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            return try encoder.encode(metadata)
        } catch {
            throw BundleError.invalidMetadata
        }
    }

    private nonisolated static func decodeMetadata<T: Codable>(_ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maxMetadataBytes else {
            throw BundleError.metadataTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let metadata = try? decoder.decode(T.self, from: data),
              let canonical = try? encodeMetadata(metadata),
              canonical == data else {
            throw BundleError.invalidMetadata
        }
        return metadata
    }

    private nonisolated static func checkedTotalLength(_ lengths: [Int]) throws -> Int {
        var total = 0
        for length in lengths {
            guard length >= 0 else { throw BundleError.invalidMetadata }
            let (next, overflow) = total.addingReportingOverflow(length)
            guard !overflow, next <= maxFileBytes else { throw BundleError.fileTooLarge }
            total = next
        }
        return total
    }

    private nonisolated static func validateTurns(_ turns: [Turn], exposedAt: Date) throws {
        guard turns.count <= maxTurns else { throw BundleError.tooManyTurns }
        guard exposedAt.timeIntervalSince1970.isFinite else { throw BundleError.invalidMetadata }
        for turn in turns {
            guard turn.actionRaw.utf8.count <= maxActionBytes,
                  turn.promptTitle.utf8.count <= maxPromptBytes,
                  turn.resultText.utf8.count <= maxResultBytes,
                  turn.date.timeIntervalSince1970.isFinite,
                  !hasForbiddenControls(turn.actionRaw),
                  !hasForbiddenControls(turn.promptTitle),
                  !hasForbiddenControls(turn.resultText) else {
                throw BundleError.invalidTurn
            }
        }
    }

    /// Strict enough to reject traversal/hidden path tricks in the authenticated decoder. The
    /// extension allow-list remains the separate recipient policy in `ShareImportPolicy`.
    private nonisolated static func isValidFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maxFileNameBytes
            && value != "." && value != ".."
            && !value.hasPrefix(".") && !value.hasSuffix(".")
            && !value.hasPrefix("~")
            && !value.contains("/") && !value.contains("\\") && !value.contains(":")
            && !value.unicodeScalars.contains(where: {
                $0.value < 0x20 || $0.value == 0x7F
            })
            && (value as NSString).isAbsolutePath == false
            && (value as NSString).lastPathComponent == value
    }

    private nonisolated static func normalizedFileNameKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private nonisolated static func hasForbiddenControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let code = scalar.value
            return (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) || code == 0x7F
        }
    }
}
