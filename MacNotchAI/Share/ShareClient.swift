import Foundation
import Security

/// Strict client for the public session-sharing v2 protocol.
///
/// The visible six-digit Session ID is a reusable, low-assurance bearer credential. Resolving it
/// creates an independent, short-lived claim capability for one recipient. A separate owner
/// capability is generated and retained only by the sender and is required to revoke a share; it
/// is never put in a URL, log, UserDefaults, or recipient response.
enum ShareClient {

    nonisolated static let maximumResponseJSONBytes = 64 * 1_024

    struct Created: Sendable {
        let sessionID: ShareSessionID
        let shareID: String
        let expiresAt: Date
    }

    /// Generated and durably stored by the Mac before a mutating request starts. If the server
    /// commits but its HTTP response is lost, Dragaway still knows both the object address and the
    /// sole revoke capability; an unconfirmed share therefore never becomes unrevokable.
    struct CreateIntent: Sendable {
        let shareID: String       // 128 random bits
        let ownerToken: String    // 256 random bits
    }

    struct Claim: Sendable {
        let shareID: String
        let claimToken: String
        let endpoint: URL
        let expiresAt: Date
        let claimExpiresAt: Date
        let descriptor: ShareCrypto.Descriptor
        let key: Data?
    }

    enum ShareError: LocalizedError, Equatable {
        case notConfigured
        case tooLarge(Int)
        case notFound
        case expired
        case claimExpired
        case rateLimited
        case invalidResponse
        case server(String)
        case offline

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Session Sharing is not configured."
            case .tooLarge(let bytes):
                let limit = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return "These files are too large to share together (combined limit \(limit))."
            case .notFound:
                return "No active session was found for that Session ID."
            case .expired:
                return "That session has expired or was revoked."
            case .claimExpired:
                return "The download authorization expired. Enter the Session ID again."
            case .rateLimited:
                return "Too many attempts. Wait a moment and try again."
            case .invalidResponse:
                return "The sharing service returned an invalid response."
            case .offline:
                return "The sharing service could not be reached."
            case .server(let message):
                return message
            }
        }
    }

    // MARK: - Expose

    static func makeCreateIntent() throws -> CreateIntent {
        CreateIntent(
            shareID: base64URL(try secureRandomData(byteCount: 16)),
            ownerToken: base64URL(try secureRandomData(byteCount: 32))
        )
    }

    static func create(sealed: ShareCrypto.Sealed,
                       endpoint: URL,
                       intent: CreateIntent) async throws -> Created {
        guard sealed.payload.count <= ShareCrypto.maxEncryptedPayloadBytes else {
            throw ShareError.tooLarge(ShareBundle.maxFileBytes)
        }
        guard decodeBase64URL(intent.shareID)?.count == 16,
              decodeBase64URL(intent.ownerToken)?.count == 32 else {
            throw ShareError.invalidResponse
        }
        try sealed.descriptor.validate()

        var request = URLRequest(url: endpoint
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("shares"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(String(sealed.payload.count), forHTTPHeaderField: "Content-Length")
        request.setValue(sealed.tier.rawValue, forHTTPHeaderField: "X-Dragaway-Tier")
        request.setValue(String(sealed.descriptor.cryptoVersion),
                         forHTTPHeaderField: "X-Dragaway-Crypto-Version")
        request.setValue(String(sealed.descriptor.bundleVersion),
                         forHTTPHeaderField: "X-Dragaway-Bundle-Version")
        request.setValue(ShareCrypto.cipherName, forHTTPHeaderField: "X-Dragaway-Cipher")
        request.setValue(intent.shareID, forHTTPHeaderField: "X-Dragaway-Share-ID")
        request.setValue(intent.ownerToken, forHTTPHeaderField: "X-Dragaway-Owner-Token")

        switch sealed.tier {
        case .codeOnly:
            guard let key = sealed.uploadKey, key.count == ShareCrypto.keyBytes else {
                throw ShareCrypto.ShareCryptoError.invalidKeyMaterial
            }
            request.setValue(ShareCrypto.noKDFName, forHTTPHeaderField: "X-Dragaway-Kdf")
            request.setValue(base64URL(key), forHTTPHeaderField: "X-Dragaway-Key")

        case .password:
            guard sealed.uploadKey == nil,
                  let salt = sealed.descriptor.salt,
                  salt.count == ShareCrypto.saltBytes else {
                throw ShareCrypto.ShareCryptoError.invalidDescriptor
            }
            request.setValue(ShareCrypto.passwordKDFName, forHTTPHeaderField: "X-Dragaway-Kdf")
            request.setValue(base64URL(salt), forHTTPHeaderField: "X-Dragaway-Kdf-Salt")
            request.setValue(String(sealed.descriptor.iterations),
                             forHTTPHeaderField: "X-Dragaway-Kdf-Iterations")
        }
        request.httpBody = sealed.payload

        let response: CreateResponse = try await sendJSON(request, expectedStatus: 201)
        guard let sessionID = ShareSessionID(rawValue: response.sessionID),
              response.shareID == intent.shareID else {
            throw ShareError.invalidResponse
        }
        let expiry = try validatedExpiry(response.expiresAt)
        return Created(sessionID: sessionID, shareID: response.shareID, expiresAt: expiry)
    }

    // MARK: - Join

    /// Resolves a reusable Session ID into a per-recipient claim. Claim creation does not consume
    /// or mutate the share, so another colleague can resolve the same ID later.
    static func claim(sessionID: ShareSessionID, endpoint: URL) async throws -> Claim {
        var request = URLRequest(url: endpoint
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("claims"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(ClaimRequest(sessionID: sessionID.rawValue))

        let response: ClaimResponse = try await sendJSON(request, expectedStatus: 200)
        guard isValidOpaqueID(response.shareID),
              isValidCapability(response.claimToken),
              let tier = ShareCrypto.Tier(rawValue: response.tier) else {
            throw ShareError.invalidResponse
        }

        let expiry = try validatedExpiry(response.expiresAt)
        let claimExpiry = Date(timeIntervalSince1970: response.claimExpiresAt)
        guard claimExpiry.timeIntervalSince1970.isFinite,
              claimExpiry > Date().addingTimeInterval(-60),
              claimExpiry <= expiry else {
            throw ShareError.invalidResponse
        }

        let descriptor: ShareCrypto.Descriptor
        let key: Data?
        switch tier {
        case .codeOnly:
            guard response.crypto.cryptoVersion == ShareCrypto.cryptoVersion,
                  ShareBundle.supports(version: response.crypto.bundleVersion),
                  response.crypto.cipher == ShareCrypto.cipherName,
                  response.crypto.kdf == ShareCrypto.noKDFName,
                  response.crypto.kdfIterations == 0,
                  response.crypto.kdfSalt == nil,
                  let encodedKey = response.key,
                  let decodedKey = decodeBase64URL(encodedKey),
                  decodedKey.count == ShareCrypto.keyBytes else {
                throw ShareError.invalidResponse
            }
            descriptor = .codeOnly(bundleVersion: response.crypto.bundleVersion)
            key = decodedKey

        case .password:
            guard response.crypto.cryptoVersion == ShareCrypto.cryptoVersion,
                  ShareBundle.supports(version: response.crypto.bundleVersion),
                  response.crypto.cipher == ShareCrypto.cipherName,
                  response.crypto.kdf == ShareCrypto.passwordKDFName,
                  response.crypto.kdfIterations == ShareCrypto.passwordIterations,
                  let encodedSalt = response.crypto.kdfSalt,
                  let salt = decodeBase64URL(encodedSalt),
                  salt.count == ShareCrypto.saltBytes,
                  response.key == nil else {
                throw ShareError.invalidResponse
            }
            descriptor = .password(
                salt: salt,
                bundleVersion: response.crypto.bundleVersion
            )
            key = nil
        }
        try descriptor.validate()

        return Claim(shareID: response.shareID, claimToken: response.claimToken,
                     endpoint: endpoint, expiresAt: expiry, claimExpiresAt: claimExpiry,
                     descriptor: descriptor, key: key)
    }

    /// Downloads ciphertext with the short-lived claim capability. A claim can be retried a small
    /// number of times server-side, but there is intentionally no lifetime recipient/fetch cap.
    static func fetchPayload(for claim: Claim) async throws -> Data {
        guard claim.claimExpiresAt > Date() else { throw ShareError.claimExpired }
        var request = URLRequest(url: claim.endpoint
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("shares", isDirectory: true)
            .appendingPathComponent(claim.shareID, isDirectory: true)
            .appendingPathComponent("payload"))
        request.httpMethod = "GET"
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(claim.claimToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await send(request,
                                              maximumBytes: ShareCrypto.maxEncryptedPayloadBytes)
        guard response.statusCode == 200,
              response.mimeType?.lowercased() == "application/octet-stream",
              data.count >= ShareCrypto.gcmOverheadBytes,
              data.count <= ShareCrypto.maxEncryptedPayloadBytes else {
            throw ShareError.invalidResponse
        }
        return data
    }

    // MARK: - Revoke

    static func revoke(record: ActiveShareRecord, ownerToken: String) async throws {
        guard let endpoint = BackendConfig.validatedShareBaseURL(record.endpoint),
              isValidOpaqueID(record.shareID),
              isValidCapability(ownerToken) else {
            throw ShareError.notConfigured
        }
        var request = URLRequest(url: endpoint
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("shares", isDirectory: true)
            .appendingPathComponent(record.shareID))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await send(request, maximumBytes: maximumResponseJSONBytes)
        guard response.statusCode == 204, data.isEmpty else {
            throw ShareError.invalidResponse
        }
    }

    // MARK: - Wire types

    private struct ClaimRequest: Encodable {
        let sessionID: String
        enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
    }

    private struct CreateResponse: Decodable {
        let sessionID: String
        let shareID: String
        let expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case shareID = "share_id"
            case expiresAt = "expires_at"
        }
    }

    private struct ClaimResponse: Decodable {
        let shareID: String
        let claimToken: String
        let expiresAt: TimeInterval
        let claimExpiresAt: TimeInterval
        let tier: String
        let crypto: CryptoResponse
        let key: String?

        enum CodingKeys: String, CodingKey {
            case shareID = "share_id"
            case claimToken = "claim_token"
            case expiresAt = "expires_at"
            case claimExpiresAt = "claim_expires_at"
            case tier, crypto, key
        }
    }

    private struct CryptoResponse: Decodable {
        let cryptoVersion: Int
        let bundleVersion: Int
        let cipher: String
        let kdf: String
        let kdfIterations: UInt32
        let kdfSalt: String?

        enum CodingKeys: String, CodingKey {
            case cryptoVersion = "crypto_version"
            case bundleVersion = "bundle_version"
            case cipher, kdf
            case kdfIterations = "kdf_iterations"
            case kdfSalt = "kdf_salt"
        }
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let code: String?
            let message: String?
        }
        let error: Detail?
    }

    // MARK: - Transport

    private static func sendJSON<Response: Decodable>(
        _ request: URLRequest,
        expectedStatus: Int
    ) async throws -> Response {
        let (data, response) = try await send(request, maximumBytes: maximumResponseJSONBytes)
        guard response.statusCode == expectedStatus,
              response.mimeType?.lowercased() == "application/json" else {
            throw ShareError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ShareError.invalidResponse
        }
    }

    /// Uses an ephemeral session whose delegate rejects an oversized declared length before body
    /// transfer and cancels the task as soon as streamed bytes would cross the exact bound. This
    /// bounds both RAM and temporary-disk/network exposure even for a malicious self-host. Redirects
    /// are refused so bearer capabilities cannot cross an origin or be replayed to another path.
    private static func send(_ request: URLRequest,
                             maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = max(request.timeoutInterval, 90)

        let delegate = BoundedRequestDelegate(maximumBytes: maximumBytes)
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await delegate.perform(request, configuration: configuration)
        } catch BoundedRequestDelegate.TransferError.limitExceeded {
            throw ShareError.invalidResponse
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ShareError.offline
        }

        guard let response = rawResponse as? HTTPURLResponse else {
            throw ShareError.invalidResponse
        }

        guard (200...299).contains(response.statusCode) else {
            throw mappedError(status: response.statusCode, body: data)
        }
        return (data, response)
    }

    private static func mappedError(status: Int, body: Data) -> ShareError {
        switch status {
        case 401, 403: return .claimExpired
        case 404:      return .notFound
        case 410:      return .expired
        case 413:      return .tooLarge(ShareBundle.maxFileBytes)
        case 429:      return .rateLimited
        default:
            let raw = (try? JSONDecoder().decode(ErrorResponse.self, from: body))?
                .error?.message ?? ""
            let clean = raw
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .server(clean.isEmpty ? "Session sharing failed (\(status))."
                                         : String(clean.prefix(300)))
        }
    }

    private static func validatedExpiry(_ seconds: TimeInterval) throws -> Date {
        let expiry = Date(timeIntervalSince1970: seconds)
        let now = Date()
        guard seconds.isFinite,
              expiry > now.addingTimeInterval(-60),
              expiry <= now.addingTimeInterval(26 * 60 * 60) else {
            throw ShareError.invalidResponse
        }
        return expiry
    }

    private static func isValidOpaqueID(_ value: String) -> Bool {
        guard (16...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy(isBase64URLByte)
    }

    private static func isValidCapability(_ value: String) -> Bool {
        guard (32...1_024).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy(isBase64URLByte)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy(isBase64URLByte) else { return nil }
        var standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: standard, options: []),
              base64URL(decoded) == value else { return nil }
        return decoded
    }

    private nonisolated static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 95
    }

    private static func secureRandomData(byteCount: Int) throws -> Data {
        guard byteCount > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw ShareCrypto.ShareCryptoError.randomGenerationFailed
        }
        return Data(bytes)
    }
}

/// One-shot bounded URLSession delegate. Its serial delegate queue owns response/body mutation;
/// the lock only coordinates task cancellation and exactly-once continuation completion.
private final class BoundedRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum TransferError: Error { case limitExceeded }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var response: URLResponse?
    private var body = Data()
    private var completed = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func perform(_ request: URLRequest,
                 configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        let queue = OperationQueue()
        queue.name = "com.aidrop.share.bounded-response"
        queue.maxConcurrentOperationCount = 1

        let session = URLSession(configuration: configuration,
                                 delegate: self,
                                 delegateQueue: queue)
        let task = session.dataTask(with: request)
        install(session: session, task: task)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let wasCompleted = completed
                lock.unlock()
                if wasCompleted {
                    finish(.failure(CancellationError()))
                } else {
                    task.resume()
                }
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let declared = response.expectedContentLength
        guard declared < 0 || declared <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(TransferError.limitExceeded))
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard data.count <= maximumBytes - body.count else {
            dataTask.cancel()
            finish(.failure(TransferError.limitExceeded))
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((body, response)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    private func install(session: URLSession, task: URLSessionDataTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }
}
