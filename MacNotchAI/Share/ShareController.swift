import AppKit
import Combine
import Foundation

/// Orchestrates the explicit sender action and the recipient's local snapshot import.
///
/// Nothing is uploaded during `prepare`. `expose` is the sole network boundary on the sender's
/// side. A recipient always receives a new immutable local fork; no subsequent action is synced to
/// the sender, the service, or another recipient.
@MainActor
final class ShareController: ObservableObject {

    static let shared = ShareController()
    private init() {}

    enum Phase: Equatable {
        case idle
        case packing
        case uploading
        case exposed(record: ActiveShareRecord, hasPassword: Bool)
        case revoking
        case failed(String)
    }

    struct PendingImport: Sendable {
        fileprivate let claim: ShareClient.Claim
        fileprivate let payload: Data

        var expiresAt: Date { claim.expiresAt }
    }

    enum ImportResult {
        case success(UUID)
        case needsPassword(PendingImport)
        case failure(String)
    }

    enum ControllerError: LocalizedError {
        case noEndpoint
        case ownerCredentialUnavailable
        case ownerRevokeUnconfirmed
        case ownerCredentialCouldNotBeSaved
        case ownerRecordCouldNotBeActivated
        case dropsQuotaExceeded

        var errorDescription: String? {
            switch self {
            case .noEndpoint:
                return "Session Sharing is not configured."
            case .ownerCredentialUnavailable:
                return "This Mac no longer has the owner credential required to revoke the share."
            case .ownerRevokeUnconfirmed:
                return "The service could not confirm this revoke. Dragaway kept the owner capability so you can retry; it will be removed after the share's confirmed local expiry."
            case .ownerCredentialCouldNotBeSaved:
                return "The revoke credential could not be saved securely, so nothing was uploaded. Revoke an older exposed session or check Keychain access and try again."
            case .ownerRecordCouldNotBeActivated:
                return "The share was accepted, but its local Session ID state could not be saved. Dragaway retained the revoke capability and attempted cleanup."
            case .dropsQuotaExceeded:
                return "The shared file does not fit Dragaway's 512 MB private Drops limit without deleting a saved session. Remove an older session and try again."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pendingFileName = ""
    @Published private(set) var pendingSize = ""

    private var operation: Task<Void, Never>?
    private var currentShare: ActiveShareRecord?

    // MARK: - Expose

    /// Populates disclosure copy from local metadata only. No file bytes are read and no request is
    /// made before the user presses “Expose Session”.
    func prepare(fileURL: URL, turns: [SessionTurn]) {
        operation?.cancel()
        operation = nil
        currentShare = nil
        pendingFileName = fileURL.lastPathComponent
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        pendingSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        phase = .idle
    }

    func expose(fileURL: URL, turns: [SessionTurn], password: String?) {
        guard let endpoint = BackendConfig.shareBaseURL else {
            phase = .failed(ControllerError.noEndpoint.localizedDescription)
            return
        }

        operation?.cancel()
        phase = .packing
        currentShare = nil

        // Convert actor-isolated persistence models before detached file I/O / PBKDF2 work.
        let wireTurns = turns.map {
            ShareBundle.Turn(actionRaw: $0.actionRaw, promptTitle: $0.promptTitle,
                             resultText: $0.resultText, date: $0.date)
        }
        let passwordCopy = password
        let exposedAt = Date()

        operation = Task { [weak self] in
            guard let self else { return }
            var trackedCreate: ActiveShareRecord?
            do {
                let sealed = try await Task.detached(priority: .userInitiated) {
                    let bundle = try ShareBundle.load(from: fileURL, turns: wireTurns,
                                                      exposedAt: exposedAt)
                    _ = try ShareImportPolicy.validatedFileName(bundle.fileName)
                    return try ShareCrypto.seal(bundle, password: passwordCopy)
                }.value
                try Task.checkCancellation()

                // Generate both opaque server address and owner capability locally, then persist
                // them before the mutating POST. Even if the server commits and its response is
                // lost, this Mac can still address and revoke the unconfirmed remote object.
                let intent = try ShareClient.makeCreateIntent()
                let pending = ActiveShareRecord(
                    state: .creating,
                    shareID: intent.shareID,
                    sessionID: nil,
                    fileName: fileURL.lastPathComponent,
                    endpoint: endpoint.absoluteString,
                    expiresAt: exposedAt.addingTimeInterval(26 * 60 * 60),
                    createdAt: exposedAt
                )
                guard ActiveShareStore.shared.addPending(
                    pending, ownerToken: intent.ownerToken) else {
                    throw ControllerError.ownerCredentialCouldNotBeSaved
                }
                trackedCreate = pending

                phase = .uploading
                // Once the mutating create request starts, let it reach a definitive response even
                // if the panel closes. The durable pending record above also covers a lost response.
                let upload = Task {
                    try await ShareClient.create(sealed: sealed, endpoint: endpoint, intent: intent)
                }
                let created: ShareClient.Created
                do {
                    created = try await upload.value
                } catch {
                    // The POST outcome may be ambiguous. Revoke immediately when possible, but a
                    // generic 404 is not proof of absence (the Worker intentionally hides bad
                    // owner tokens and unknown IDs alike), so failed cleanup keeps the pending
                    // capability until confirmed 204 or local expiry.
                    switch error {
                    case ShareClient.ShareError.rateLimited,
                         ShareClient.ShareError.tooLarge(_):
                        // In the v2 contract both checks run before identifier reservation/R2 put,
                        // so these responses definitively prove that no remote object was created.
                        ActiveShareStore.shared.remove(pending)
                    default:
                        _ = await cleanupTrackedShare(pending, ownerToken: intent.ownerToken)
                    }
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }

                guard let record = ActiveShareStore.shared.promote(
                    pending, sessionID: created.sessionID, expiresAt: created.expiresAt) else {
                    _ = await cleanupTrackedShare(pending, ownerToken: intent.ownerToken)
                    throw ControllerError.ownerRecordCouldNotBeActivated
                }
                trackedCreate = record

                // Persist before checking cancellation. If the panel closed while create was in
                // flight, an offline/failed revoke then remains visible in Active Exposed Sessions
                // with its Keychain capability intact instead of becoming an orphan until expiry.
                if Task.isCancelled {
                    _ = await cleanupTrackedShare(record, ownerToken: intent.ownerToken)
                    throw CancellationError()
                }

                currentShare = record
                phase = .exposed(record: record, hasPassword: sealed.tier == .password)
                operation = nil
                // Onboarding advances on the real outcome — a share that exists — not on the
                // keypress, so a failed upload never marks the step complete.
                NotificationCenter.default.post(name: .tutorialEvent, object: "expose")
            } catch is CancellationError {
                // `reset()` already put the UI in its intended state.
            } catch {
                let isStillTracked = trackedCreate.map { tracked in
                    ActiveShareStore.shared.ownedShares.contains { $0.id == tracked.id }
                } ?? false
                let retained = isStillTracked
                    ? " Dragaway kept the owner capability locally so you can retry Revoke from Active Exposed Sessions; the remote object expires automatically."
                    : ""
                phase = .failed(error.localizedDescription + retained)
                operation = nil
            }
        }
    }

    /// Revokes the share currently shown in the sender panel. The local owner capability is removed
    /// only after the service confirms deletion with 204.
    func revoke() {
        guard let record = currentShare else { return }
        operation?.cancel()
        phase = .revoking
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await revoke(record)
                currentShare = nil
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
            operation = nil
        }
    }

    /// Menu-bar revocation for any locally tracked active share. Offline failures deliberately keep
    /// both record and owner token, allowing the user to retry later.
    func revoke(_ record: ActiveShareRecord) async throws {
        guard let ownerToken = ActiveShareStore.shared.ownerToken(for: record) else {
            throw ControllerError.ownerCredentialUnavailable
        }
        do {
            try await ShareClient.revoke(record: record, ownerToken: ownerToken)
            ActiveShareStore.shared.remove(record)
        } catch ShareClient.ShareError.notFound {
            // `/v2` deliberately returns the same 404 for an unknown object and a wrong owner
            // capability. Deleting our only credential here would turn ambiguity into data loss.
            throw ControllerError.ownerRevokeUnconfirmed
        }
    }

    /// Cleanup requests are unstructured so closing the panel cannot cancel them after they start.
    /// Only a confirmed 204 removes the local credential; every ambiguous response retains it.
    private func cleanupTrackedShare(_ record: ActiveShareRecord,
                                     ownerToken: String) async -> Bool {
        let cleanup = Task {
            try await ShareClient.revoke(record: record, ownerToken: ownerToken)
        }
        do {
            try await cleanup.value
            ActiveShareStore.shared.remove(record)
            return true
        } catch {
            return false
        }
    }

    /// Closing the panel cancels local work; it never revokes an already-created share. Successfully
    /// created shares remain available through Active Exposed Sessions until explicit revoke/expiry.
    func reset() {
        operation?.cancel()
        operation = nil
        currentShare = nil
        phase = .idle
    }

    // MARK: - Import

    /// Resolves and downloads once. Password shares stop with the ciphertext cached only in memory,
    /// so every password retry is local and does not consume another server claim or disclose input.
    func beginImport(sessionID: ShareSessionID) async -> ImportResult {
        guard let endpoint = BackendConfig.shareBaseURL else {
            return .failure(ControllerError.noEndpoint.localizedDescription)
        }
        do {
            let claim = try await ShareClient.claim(sessionID: sessionID, endpoint: endpoint)
            let payload = try await ShareClient.fetchPayload(for: claim)
            let pending = PendingImport(claim: claim, payload: payload)

            if claim.descriptor.tier == .password {
                return .needsPassword(pending)
            }
            return await finishImport(pending, password: nil)
        } catch is CancellationError {
            return .failure("Joining was cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Decrypts, validates and writes the already-downloaded snapshot. A wrong password returns the
    /// same `PendingImport`, preserving local retry without network traffic.
    func finishImport(_ pending: PendingImport, password: String?) async -> ImportResult {
        let dropsDirectory = DropMaterializer.dropsDirectory()
        do {
            let bundle = try await Task.detached(priority: .userInitiated) {
                let opened = try ShareCrypto.open(
                    payload: pending.payload,
                    descriptor: pending.claim.descriptor,
                    key: pending.claim.key,
                    password: password?.isEmpty == false ? password : nil
                )
                _ = try ShareImportPolicy.validatedFileName(opened.fileName)
                return opened
            }.value
            try Task.checkCancellation()

            guard let reservation = DropMaterializer.reserveShareImport(
                fileName: bundle.fileName, byteCount: bundle.fileData.count) else {
                throw ControllerError.dropsQuotaExceeded
            }
            var reservationIsActive = true
            var uncommittedFileURL: URL?
            defer {
                if let uncommittedFileURL {
                    try? FileManager.default.removeItem(at: uncommittedFileURL)
                }
                if reservationIsActive {
                    DropMaterializer.releaseShareImport(reservation)
                }
            }

            let destination = try await Task.detached(priority: .userInitiated) {
                try ShareImportPolicy.persist(
                    bundle,
                    in: dropsDirectory,
                    reservedDestinationAttempt: reservation.destinationAttempt,
                    tempIdentifier: reservation.id
                )
            }.value
            uncommittedFileURL = destination
            let imported = ImportedSnapshot(bundle: bundle, fileURL: destination)

            // After an atomic file write succeeds, always persist its local history identity even
            // if the Join window closed meanwhile. This avoids an invisible orphan file; the user
            // can reopen the completed fork from Recent Sessions.
            let turns = imported.bundle.turns.map {
                SessionTurn(actionRaw: $0.actionRaw, promptTitle: $0.promptTitle,
                            resultText: $0.resultText, date: $0.date)
            }
            let localID = try SessionHistoryStore.shared.createImportedSession(
                primary: imported.fileURL,
                turns: turns,
                updatedAt: imported.bundle.turns.last?.date ?? imported.bundle.exposedAt
            )
            // History now owns the final path. Only now may a later prune stop treating the temp/
            // destination pair as an in-flight reservation.
            DropMaterializer.releaseShareImport(reservation, preserving: [imported.fileURL])
            reservationIsActive = false
            uncommittedFileURL = nil
            // Posted only once the fork is durably in History — not on download or decrypt.
            NotificationCenter.default.post(name: .tutorialEvent, object: "joinSession")
            return .success(localID)
        } catch ShareCrypto.ShareCryptoError.wrongPassword {
            return .needsPassword(pending)
        } catch ShareCrypto.ShareCryptoError.invalidPasswordLength {
            return .needsPassword(pending)
        } catch is CancellationError {
            return .failure("Joining was cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private struct ImportedSnapshot: Sendable {
    let bundle: ShareBundle
    let fileURL: URL
}
