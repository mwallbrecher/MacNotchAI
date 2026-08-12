import Foundation
import Combine
import CryptoKit

/// Non-secret local metadata for a share the user created. The matching owner
/// token is deliberately excluded from Codable storage and lives only in the
/// Keychain service derived from `shareID`.
struct ActiveShareRecord: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        /// Owner capability is already durable, but the mutating create response has not yet
        /// been confirmed locally. This state is intentionally revocable but not shareable.
        case creating
        case active
    }

    let state: State
    let shareID: String
    let sessionID: String?
    let fileName: String
    let endpoint: String
    let expiresAt: Date
    let createdAt: Date

    /// Compound endpoint + server object identity. A custom endpoint can deliberately return the
    /// same opaque ID as the hosted service; hashing the pair prevents it from replacing the other
    /// service's Keychain capability or local record.
    var id: String {
        var material = Data(endpoint.utf8)
        material.append(0)
        material.append(contentsOf: shareID.utf8)
        return Data(SHA256.hash(data: material)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Remembers shares that can still be revoked by this Mac without ever writing an
/// owner credential into Application Support. Metadata is bounded and validated
/// on both insertion and decoding because the JSON file is local input, not trust.
@MainActor
final class ActiveShareStore: ObservableObject {
    static let shared = ActiveShareStore()

    @Published private(set) var shares: [ActiveShareRecord] = []

    /// Current, unexpired records in newest-first order. The date filter is applied
    /// at read time as well as during pruning, so an open menu cannot show a share
    /// merely because no cleanup timer fired at its exact expiry second.
    var activeShares: [ActiveShareRecord] {
        let now = Date()
        return shares
            .filter { $0.state == .active && $0.expiresAt > now }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Includes unconfirmed creates so an ambiguous/lost create response never strands the only
    /// revoke capability. Pending records expose no Session ID but remain manageable in the menu.
    var ownedShares: [ActiveShareRecord] {
        let now = Date()
        return shares
            .filter { $0.expiresAt > now }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static let formatVersion = 3
    private static let maximumRecordCount = 100
    private static let maximumJSONBytes = 256 * 1024
    private static let maximumShareIDLength = 128
    private static let maximumFileNameUTF8Bytes = 255
    private static let maximumEndpointLength = 2_048
    private static let maximumOwnerTokenLength = 1_024
    private static let ownerServicePrefix = "com.aidrop.share.owner."

    private struct PersistedEnvelope: Codable {
        let version: Int
        let records: [ActiveShareRecord]
    }

    /// Bind the capability to its routing coordinates inside the Keychain. Application Support is
    /// writable by other processes running as the user; without this binding, tampering a record's
    /// endpoint could trick Dragaway into sending a valid owner token to an attacker's server.
    private struct OwnerCredential: Codable {
        let version: Int
        let shareID: String
        let endpoint: String
        let token: String
    }

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.wallbrecher.MacNotchAI"
        let directory = base.appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("active_shares.json")
        load()
        pruneExpired()
    }

    // MARK: - Mutation

    /// Persist a revoke capability before the first mutating create request is sent. The record is
    /// capacity-checked here, so hitting the local 100-share safety bound cannot happen after a
    /// server commit. Existing identities are never replaced.
    @discardableResult
    func addPending(_ record: ActiveShareRecord, ownerToken: String) -> Bool {
        let now = Date()
        guard record.state == .creating,
              Self.isValid(record, now: now),
              Self.isValidOwnerToken(ownerToken) else { return false }

        pruneExpired(now: now)

        let retained = shares.filter { $0.expiresAt > now }
        // Never evict an unexpired owner capability merely to make room for another share. That
        // would leave a live remote object which this Mac can no longer revoke.
        guard retained.count < Self.maximumRecordCount,
              !retained.contains(where: { Self.sameIdentity($0, record) }),
              let encodedCredential = Self.encodeCredential(
                ownerToken: ownerToken, record: record) else { return false }

        let service = Self.ownerService(for: record)
        let previousCredential = KeychainManager.shared.load(service: service)
        guard KeychainManager.shared.save(key: encodedCredential, service: service) else {
            return false
        }

        let candidate = Self.sorted(retained + [record])

        guard persist(candidate) else {
            if let previousCredential {
                _ = KeychainManager.shared.save(key: previousCredential, service: service)
            } else {
                KeychainManager.shared.delete(service: service)
            }
            return false
        }

        shares = candidate
        return true
    }

    /// Atomically make an already-tracked create visible to recipients. If the JSON write fails,
    /// the durable `.creating` record and Keychain credential remain intact for later revoke.
    func promote(_ pending: ActiveShareRecord,
                 sessionID: ShareSessionID,
                 expiresAt: Date) -> ActiveShareRecord? {
        let now = Date()
        guard pending.state == .creating,
              let index = shares.firstIndex(where: { Self.sameIdentity($0, pending) }),
              shares[index].state == .creating else { return nil }

        let active = ActiveShareRecord(
            state: .active,
            shareID: pending.shareID,
            sessionID: sessionID.rawValue,
            fileName: pending.fileName,
            endpoint: pending.endpoint,
            expiresAt: expiresAt,
            createdAt: pending.createdAt
        )
        guard Self.isValid(active, now: now),
              ownerToken(for: pending) != nil else { return nil }

        var candidate = shares
        candidate[index] = active
        guard persist(candidate) else { return nil }
        shares = Self.sorted(candidate)
        return active
    }

    /// Load the owner credential for a known local record. A missing Keychain value
    /// is treated as unavailable rather than falling back to JSON or another store.
    func ownerToken(for record: ActiveShareRecord) -> String? {
        guard shares.contains(where: { Self.sameIdentity($0, record) }),
              Self.isValidShareID(record.shareID),
              let encoded = KeychainManager.shared.load(service: Self.ownerService(for: record)),
              let credential = Self.decodeCredential(encoded),
              credential.shareID == record.shareID,
              credential.endpoint == record.endpoint,
              Self.isValidOwnerToken(credential.token) else { return nil }
        return credential.token
    }

    /// Forget local revoke state and delete its Keychain credential. This performs
    /// no network operation; the caller must revoke remotely before removing it when
    /// early server deletion is desired.
    func remove(_ record: ActiveShareRecord) {
        guard Self.isValidShareID(record.shareID) else { return }
        let candidate = shares.filter { !Self.sameIdentity($0, record) }
        guard candidate.count != shares.count else {
            KeychainManager.shared.delete(service: Self.ownerService(for: record))
            return
        }

        // Publish only a state that was successfully persisted. A stale Keychain
        // token is safer than a metadata row whose sole credential has been lost.
        guard persist(candidate) else { return }
        shares = candidate
        KeychainManager.shared.delete(service: Self.ownerService(for: record))
    }

    /// Remove expired metadata and its per-share owner credentials. The optional
    /// date makes the boundary deterministic for tests and callers doing batch work.
    func pruneExpired(now: Date = Date()) {
        let expired = shares.filter { $0.expiresAt <= now }
        guard !expired.isEmpty else { return }
        let candidate = shares.filter { $0.expiresAt > now }
        guard persist(candidate) else { return }
        shares = candidate
        for record in expired {
            KeychainManager.shared.delete(service: Self.ownerService(for: record))
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0, size <= Self.maximumJSONBytes,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              data.count <= Self.maximumJSONBytes,
              let envelope = try? JSONDecoder().decode(PersistedEnvelope.self, from: data),
              envelope.version == Self.formatVersion else { return }

        var seen = Set<String>()
        var decoded: [ActiveShareRecord] = []
        var shouldRewrite = envelope.records.count > Self.maximumRecordCount
        for record in envelope.records.prefix(Self.maximumRecordCount) {
            guard Self.isStructurallyValid(record),
                  seen.insert(record.id).inserted,
                  let encoded = KeychainManager.shared.load(
                    service: Self.ownerService(for: record)),
                  let credential = Self.decodeCredential(encoded),
                  credential.shareID == record.shareID,
                  credential.endpoint == record.endpoint,
                  Self.isValidOwnerToken(credential.token) else {
                shouldRewrite = true
                continue
            }
            decoded.append(record)
        }
        shares = Self.sorted(decoded)
        if shouldRewrite { _ = persist(shares) }
    }

    /// `Data.write(.atomic)` creates and renames a sibling temporary file, so readers
    /// observe either the previous complete envelope or the new complete envelope.
    private func persist(_ records: [ActiveShareRecord]) -> Bool {
        guard records.count <= Self.maximumRecordCount else { return false }
        let envelope = PersistedEnvelope(version: Self.formatVersion,
                                         records: Self.sorted(records))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope),
              data.count <= Self.maximumJSONBytes else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Validation

    private static func sorted(_ records: [ActiveShareRecord]) -> [ActiveShareRecord] {
        records.sorted { $0.createdAt > $1.createdAt }
    }

    private static func ownerService(for record: ActiveShareRecord) -> String {
        ownerServicePrefix + record.id
    }

    private static func sameIdentity(_ lhs: ActiveShareRecord,
                                     _ rhs: ActiveShareRecord) -> Bool {
        lhs.shareID == rhs.shareID && lhs.endpoint == rhs.endpoint
    }

    private static func isValid(_ record: ActiveShareRecord, now: Date) -> Bool {
        isStructurallyValid(record) && record.expiresAt > now
    }

    private static func isStructurallyValid(_ record: ActiveShareRecord) -> Bool {
        guard isValidShareID(record.shareID),
              !record.fileName.isEmpty,
              record.fileName.utf8.count <= maximumFileNameUTF8Bytes,
              record.fileName != ".", record.fileName != "..",
              record.fileName == (record.fileName as NSString).lastPathComponent,
              !record.fileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              record.endpoint.utf8.count <= maximumEndpointLength,
              let endpointURL = URL(string: record.endpoint),
              let scheme = endpointURL.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              endpointURL.host != nil,
              endpointURL.user == nil, endpointURL.password == nil,
              endpointURL.query == nil, endpointURL.fragment == nil,
              record.createdAt.timeIntervalSinceReferenceDate.isFinite,
              record.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              record.expiresAt > record.createdAt else { return false }

        switch record.state {
        case .creating:
            guard record.sessionID == nil else { return false }
        case .active:
            guard let sessionID = record.sessionID,
                  ShareSessionID(rawValue: sessionID) != nil else { return false }
        }
        return true
    }

    private static func isValidShareID(_ shareID: String) -> Bool {
        guard (16...maximumShareIDLength).contains(shareID.utf8.count) else { return false }
        return shareID.utf8.allSatisfy(Self.isBase64URLByte)
    }

    private static func isValidOwnerToken(_ token: String) -> Bool {
        guard (32...maximumOwnerTokenLength).contains(token.utf8.count) else { return false }
        return token.utf8.allSatisfy(Self.isBase64URLByte)
    }

    private static func encodeCredential(ownerToken: String,
                                         record: ActiveShareRecord) -> String? {
        let credential = OwnerCredential(version: 1, shareID: record.shareID,
                                         endpoint: record.endpoint, token: ownerToken)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(credential), data.count <= 4 * 1_024 else {
            return nil
        }
        return data.base64EncodedString()
    }

    private static func decodeCredential(_ encoded: String) -> OwnerCredential? {
        guard encoded.utf8.count <= 8 * 1_024,
              let data = Data(base64Encoded: encoded), data.count <= 4 * 1_024,
              let credential = try? JSONDecoder().decode(OwnerCredential.self, from: data),
              credential.version == 1,
              isValidShareID(credential.shareID),
              credential.endpoint.utf8.count <= maximumEndpointLength,
              isValidOwnerToken(credential.token) else { return nil }
        return credential
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 95
    }
}
