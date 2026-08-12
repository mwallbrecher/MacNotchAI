import Darwin
import Foundation

@main
enum ShareSecuritySmoke {
    private static var checks = 0

    static func main() throws {
        try testPBKDF2Vector()
        try testEnvelopeAndCryptoRoundTrips()
        try testMultiFileEnvelopeAndBounds()
        try testEnvelopeLengthBomb()
        try testRegularFileLoading()
        testSessionIDParsing()
        try testImportPolicy()
        print("share_security_smoke: \(checks) checks passed")
    }

    private static func testPBKDF2Vector() throws {
        // PBKDF2-HMAC-SHA256 test vector: P="password", S="salt", c=1, dkLen=32.
        let derived = try ShareCrypto.pbkdf2SHA256(
            passwordBytes: Data("password".utf8),
            salt: Data("salt".utf8),
            iterations: 1,
            outputByteCount: 32
        )
        expect(
            derived.hex == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
            "CommonCrypto PBKDF2 vector"
        )
    }

    private static func testEnvelopeAndCryptoRoundTrips() throws {
        let bundle = fixtureBundle()
        let encoded = try bundle.encodeEnvelope()
        expect(encoded.prefix(8) == ShareBundle.v2EnvelopeMagic, "v2 envelope magic")
        try expect(try ShareBundle.decodeEnvelope(encoded).fileData == bundle.fileData, "binary envelope")
        let prefixed = Data([0xAA, 0xBB]) + encoded
        let nonZeroBasedSlice = prefixed[prefixed.index(prefixed.startIndex, offsetBy: 2)...]
        try expect(
            try ShareBundle.decodeEnvelope(nonZeroBasedSlice).fileData == bundle.fileData,
            "non-zero-based Data slice envelope"
        )

        let codeOnly = try ShareCrypto.seal(bundle, password: nil)
        expect(codeOnly.tier == .codeOnly, "code-only tier")
        expect(codeOnly.uploadKey?.count == 32, "code-only random key")
        let openedCodeOnly = try ShareCrypto.open(
            payload: codeOnly.payload,
            descriptor: codeOnly.descriptor,
            key: codeOnly.uploadKey,
            password: nil
        )
        expect(openedCodeOnly.turns == bundle.turns, "code-only round trip")
        expect(codeOnly.descriptor.bundleVersion == ShareBundle.legacyVersion,
               "single-file shares retain v2 descriptor")

        let passphrase = "correct horse battery staple"
        let passwordShare = try ShareCrypto.seal(bundle, password: passphrase)
        expect(passwordShare.tier == .password, "password tier")
        expect(passwordShare.uploadKey == nil, "password key never exported")
        expect(passwordShare.salt?.count == 32, "password salt")
        let descriptorData = try passwordShare.descriptor.canonicalData()
        try expect(
            try ShareCrypto.Descriptor.decodeCanonical(descriptorData) == passwordShare.descriptor,
            "canonical authenticated descriptor"
        )
        let openedPassword = try ShareCrypto.open(
            payload: passwordShare.payload,
            descriptor: passwordShare.descriptor,
            key: nil,
            password: passphrase
        )
        expect(openedPassword.fileData == bundle.fileData, "password round trip")

        expectThrows("wrong password") {
            _ = try ShareCrypto.open(
                payload: passwordShare.payload,
                descriptor: passwordShare.descriptor,
                key: nil,
                password: "this is the wrong password"
            )
        }

        var corrupted = codeOnly.payload
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
        expectThrows("GCM corruption rejection") {
            _ = try ShareCrypto.open(
                payload: corrupted,
                descriptor: codeOnly.descriptor,
                key: codeOnly.uploadKey,
                password: nil
            )
        }

        expectThrows("short password rejection") {
            _ = try ShareCrypto.seal(bundle, password: "too short")
        }

        let invalidDescriptor = ShareCrypto.Descriptor(
            cryptoVersion: ShareCrypto.cryptoVersion,
            bundleVersion: ShareBundle.version,
            cipher: ShareCrypto.cipherName,
            tier: .password,
            kdf: ShareCrypto.passwordKDFName,
            iterations: UInt32.max,
            salt: Data(repeating: 0, count: ShareCrypto.saltBytes)
        )
        expectThrows("attacker-selected KDF work factor rejection") {
            try invalidDescriptor.validate()
        }
    }

    private static func testMultiFileEnvelopeAndBounds() throws {
        let bundle = fixtureMultiBundle()
        let encoded = try bundle.encodeEnvelope()
        expect(encoded.prefix(8) == ShareBundle.v3EnvelopeMagic, "v3 envelope magic")
        let decoded = try ShareBundle.decodeEnvelope(encoded)
        expect(decoded.v == ShareBundle.multiFileVersion, "v3 bundle version")
        expect(decoded.files == bundle.files, "ordered multi-file binary envelope")

        let sealed = try ShareCrypto.seal(bundle, password: nil)
        expect(sealed.descriptor.bundleVersion == ShareBundle.multiFileVersion,
               "multi-file authenticated v3 descriptor")
        let opened = try ShareCrypto.open(
            payload: sealed.payload,
            descriptor: sealed.descriptor,
            key: sealed.uploadKey,
            password: nil
        )
        expect(opened.files == bundle.files, "multi-file crypto round trip")

        var truncated = encoded
        truncated.removeLast()
        expectThrows("v3 exact aggregate length rejection") {
            _ = try ShareBundle.decodeEnvelope(truncated)
        }

        let duplicateNames = ShareBundle(
            files: [
                .init(fileName: "Report.txt", fileData: Data([1])),
                .init(fileName: "report.txt", fileData: Data([2]))
            ],
            turns: [],
            exposedAt: Date()
        )
        expectThrows("duplicate multi-file basename rejection") {
            try duplicateNames.validate()
        }

        let sixFiles = ShareBundle(
            files: (0..<6).map {
                .init(fileName: "file-\($0).txt", fileData: Data([UInt8($0)]))
            },
            turns: [],
            exposedAt: Date()
        )
        expectThrows("six-file bundle rejection") {
            try sixFiles.validate()
        }

        let oversizedAggregate = ShareBundle(
            files: [
                .init(fileName: "large.bin.txt",
                      fileData: Data(repeating: 0, count: ShareBundle.maxFileBytes)),
                .init(fileName: "overflow.txt", fileData: Data([1]))
            ],
            turns: [],
            exposedAt: Date()
        )
        expectThrows("25 MiB aggregate bound") {
            try oversizedAggregate.validate()
        }
    }

    private static func testEnvelopeLengthBomb() throws {
        var envelope = try fixtureBundle().encodeEnvelope()
        envelope.replaceSubrange(8..<12, with: [0xFF, 0xFF, 0xFF, 0xFF])
        expectThrows("metadata length bomb rejection") {
            _ = try ShareBundle.decodeEnvelope(envelope)
        }
    }

    private static func testRegularFileLoading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragaway-share-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("input.txt")
        let expected = Data("bounded file bytes".utf8)
        try expected.write(to: file)
        let loaded = try ShareBundle.load(from: file, turns: [])
        expect(loaded.fileData == expected, "bounded regular-file load")

        var multiURLs: [URL] = []
        for index in 0..<5 {
            let url = root.appendingPathComponent("input-\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            multiURLs.append(url)
        }
        let multi = try ShareBundle.load(from: multiURLs, turns: [])
        expect(multi.files.count == 5, "five regular files load")
        expect(multi.v == ShareBundle.multiFileVersion, "multi load chooses v3")
        expectThrows("six sender files rejected") {
            _ = try ShareBundle.load(from: multiURLs + [file], turns: [])
        }

        expectThrows("directory input rejection") {
            _ = try ShareBundle.load(from: root, turns: [])
        }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        expectThrows("sender symlink rejection") {
            _ = try ShareBundle.load(from: link, turns: [])
        }
    }

    private static func testSessionIDParsing() {
        expect(ShareSessionID.parse("123456")?.rawValue == "123456", "plain Session ID")
        expect(ShareSessionID.parse(" 123-456 \n")?.rawValue == "123456", "formatted Session ID")
        expect(ShareSessionID.parse("ID: 123456") == nil, "label rejection")
        expect(ShareSessionID.parse("1234567") == nil, "oversized Session ID rejection")
    }

    private static func testImportPolicy() throws {
        for unsafe in [
            "../escape.txt", "..\\escape.txt", "/tmp/escape.txt", "disk:escape.txt",
            ".hidden.txt", "..", "payload.app", "payload.zip", "payload.dmg",
            "bad\u{0000}name.txt", String(repeating: "a", count: 256) + ".txt"
        ] {
            expectThrows("unsafe filename: \(unsafe.debugDescription)") {
                _ = try ShareImportPolicy.validatedFileName(unsafe)
            }
        }
        expectThrows("unknown extension fails closed") {
            _ = try ShareImportPolicy.validatedFileName("payload.unknown-container")
        }
        expect(
            (try? ShareImportPolicy.validatedFileName("Quarterly report.txt")) != nil,
            "supported safe filename"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragaway-share-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try ShareImportPolicy.persist(fixtureBundle(), in: root)
        let second = try ShareImportPolicy.persist(fixtureBundle(), in: root)
        expect(first.lastPathComponent == "report.txt", "first import filename")
        expect(second.lastPathComponent == "report 2.txt", "non-overwrite collision filename")
        let reservedID = UUID()
        let reserved = try ShareImportPolicy.persist(
            fixtureBundle(), in: root,
            reservedDestinationAttempt: 2, tempIdentifier: reservedID
        )
        expect(reserved.lastPathComponent == "report 3.txt", "exact reserved import filename")
        expectThrows("reserved destination collision never falls back") {
            _ = try ShareImportPolicy.persist(
                fixtureBundle(), in: root,
                reservedDestinationAttempt: 0, tempIdentifier: UUID()
            )
        }
        let lingeringReservedTemp = root.appendingPathComponent(
            ".dragaway-share-\(reservedID.uuidString).tmp"
        )
        expect(
            !FileManager.default.fileExists(atPath: lingeringReservedTemp.path),
            "reservation temp removed after atomic rename"
        )
        expect(first.deletingLastPathComponent() == root, "destination containment")
        try expect((try Data(contentsOf: first)) == fixtureBundle().fileData, "persisted bytes")
        var fileInfo = stat()
        let statResult = first.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &fileInfo)
        }
        expect(statResult == 0 && (fileInfo.st_mode & 0o777) == 0o600, "private file mode")

        let rollbackName = "batch rollback.txt"
        let rollbackURL = root.appendingPathComponent(rollbackName)
        expectThrows("reserved batch rolls back earlier members") {
            _ = try ShareImportPolicy.persistBatch([
                .init(
                    file: .init(fileName: rollbackName, fileData: Data("first".utf8)),
                    destinationAttempt: 0,
                    tempIdentifier: UUID()
                ),
                .init(
                    file: .init(fileName: "report.txt", fileData: Data("collision".utf8)),
                    destinationAttempt: 0,
                    tempIdentifier: UUID()
                )
            ], in: root)
        }
        expect(!FileManager.default.fileExists(atPath: rollbackURL.path),
               "failed batch leaves no earlier output")
        try expect((try Data(contentsOf: first)) == fixtureBundle().fileData,
                   "failed batch never overwrites existing file")

        let symlink = root.deletingLastPathComponent()
            .appendingPathComponent("dragaway-share-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: symlink) }
        expectThrows("symlink Drops directory rejection") {
            _ = try ShareImportPolicy.persist(fixtureBundle(), in: symlink)
        }
    }

    private static func fixtureBundle() -> ShareBundle {
        ShareBundle(
            fileName: "report.txt",
            fileData: Data([0x00, 0x01, 0x02, 0xFF]),
            turns: [
                .init(
                    actionRaw: "summariseBullets",
                    promptTitle: "Summarise",
                    resultText: "One concise result.",
                    date: Date(timeIntervalSince1970: 1_700_000_000.125)
                )
            ],
            exposedAt: Date(timeIntervalSince1970: 1_700_000_100.250)
        )
    }

    private static func fixtureMultiBundle() -> ShareBundle {
        ShareBundle(
            files: [
                .init(fileName: "report.txt", fileData: Data([0x00, 0x01, 0x02, 0xFF])),
                .init(fileName: "notes.md", fileData: Data("Second file".utf8))
            ],
            turns: fixtureBundle().turns,
            exposedAt: Date(timeIntervalSince1970: 1_700_000_100.250)
        )
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        checks += 1
        guard try condition() else {
            fatalError("FAILED: \(label)")
        }
    }

    private static func expectThrows(_ label: String, _ operation: () throws -> Void) {
        checks += 1
        do {
            try operation()
            fatalError("FAILED (did not throw): \(label)")
        } catch {
            // Expected.
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
