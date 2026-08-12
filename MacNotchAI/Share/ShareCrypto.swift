import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Dependency-free sharing cryptography for v2 and v3 bundle envelopes.
///
/// Both tiers use AES-256-GCM. The small, canonical `Descriptor` is authenticated as GCM AAD, so a
/// server cannot silently change the tier, KDF parameters, or expected bundle version. In the
/// password tier the key is derived locally with Apple's CommonCrypto PBKDF2 implementation and is
/// never uploaded. In the code-only tier the random key is returned as `uploadKey` for server-side
/// escrow; that tier is intentionally server-readable and must never be described as E2EE.
nonisolated enum ShareCrypto {

    nonisolated static let cryptoVersion = 2
    nonisolated static let cipherName = "aes-256-gcm-combined"
    nonisolated static let passwordKDFName = "pbkdf2-hmac-sha256"
    nonisolated static let noKDFName = "none"
    nonisolated static let passwordIterations: UInt32 = 600_000
    nonisolated static let saltBytes = 32
    nonisolated static let keyBytes = 32
    nonisolated static let minimumPasswordBytes = 12
    nonisolated static let maximumPasswordBytes = 256
    nonisolated static let maxDescriptorBytes = 1_024
    nonisolated static let gcmOverheadBytes = 12 + 16 // CryptoKit combined nonce + tag
    nonisolated static let maxEncryptedPayloadBytes = ShareBundle.maxPlaintextBytes + gcmOverheadBytes

    nonisolated enum Tier: String, Codable, Sendable {
        case codeOnly
        case password
    }

    /// Header-safe authenticated crypto metadata. `canonicalData()` is the exact AES-GCM AAD.
    nonisolated struct Descriptor: Codable, Equatable, Sendable {
        let cryptoVersion: Int
        let bundleVersion: Int
        let cipher: String
        let tier: Tier
        let kdf: String
        let iterations: UInt32
        let salt: Data?

        nonisolated static func codeOnly(
            bundleVersion: Int = ShareBundle.version
        ) -> Descriptor {
            Descriptor(
                cryptoVersion: ShareCrypto.cryptoVersion,
                bundleVersion: bundleVersion,
                cipher: ShareCrypto.cipherName,
                tier: .codeOnly,
                kdf: ShareCrypto.noKDFName,
                iterations: 0,
                salt: nil
            )
        }

        nonisolated static func password(
            salt: Data,
            bundleVersion: Int = ShareBundle.version
        ) -> Descriptor {
            Descriptor(
                cryptoVersion: ShareCrypto.cryptoVersion,
                bundleVersion: bundleVersion,
                cipher: ShareCrypto.cipherName,
                tier: .password,
                kdf: ShareCrypto.passwordKDFName,
                iterations: ShareCrypto.passwordIterations,
                salt: salt
            )
        }

        nonisolated func validate() throws {
            guard cryptoVersion == ShareCrypto.cryptoVersion,
                  ShareBundle.supports(version: bundleVersion),
                  cipher == ShareCrypto.cipherName else {
                throw ShareCryptoError.invalidDescriptor
            }

            switch tier {
            case .codeOnly:
                guard kdf == ShareCrypto.noKDFName,
                      iterations == 0,
                      salt == nil else {
                    throw ShareCryptoError.invalidDescriptor
                }
            case .password:
                // v2 accepts exactly its calibrated work factor. Refusing attacker-selected values
                // prevents a malicious descriptor from turning an import into a CPU denial of service.
                guard kdf == ShareCrypto.passwordKDFName,
                      iterations == ShareCrypto.passwordIterations,
                      salt?.count == ShareCrypto.saltBytes else {
                    throw ShareCryptoError.invalidDescriptor
                }
            }
        }

        nonisolated func canonicalData() throws -> Data {
            try validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let encoded = try? encoder.encode(self),
                  encoded.count <= ShareCrypto.maxDescriptorBytes else {
                throw ShareCryptoError.invalidDescriptor
            }
            return encoded
        }

        nonisolated static func decodeCanonical(_ data: Data) throws -> Descriptor {
            guard !data.isEmpty, data.count <= ShareCrypto.maxDescriptorBytes,
                  let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data) else {
                throw ShareCryptoError.invalidDescriptor
            }
            try descriptor.validate()
            guard try descriptor.canonicalData() == data else {
                throw ShareCryptoError.invalidDescriptor
            }
            return descriptor
        }
    }

    nonisolated struct Sealed: Sendable {
        /// CryptoKit combined form: 12-byte nonce | ciphertext | 16-byte GCM tag.
        let payload: Data
        /// Present only for `.codeOnly`; the password tier never exports key material.
        let uploadKey: Data?
        let descriptor: Descriptor

        nonisolated var tier: Tier { descriptor.tier }
        nonisolated var salt: Data? { descriptor.salt }
    }

    nonisolated enum ShareCryptoError: LocalizedError, Equatable {
        case badPayload
        case wrongPassword
        case invalidPasswordLength
        case missingKeyMaterial
        case invalidKeyMaterial
        case invalidDescriptor
        case randomGenerationFailed
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .badPayload:
                return "The shared data is damaged or incomplete."
            case .wrongPassword:
                return "Wrong password."
            case .invalidPasswordLength:
                return "Use a password between 12 and 256 UTF-8 bytes."
            case .missingKeyMaterial, .invalidKeyMaterial:
                return "The share is missing valid key material."
            case .invalidDescriptor:
                return "The share uses invalid or unsupported encryption parameters."
            case .randomGenerationFailed:
                return "Secure random data could not be generated."
            case .keyDerivationFailed:
                return "The password key could not be derived."
            }
        }
    }

    // MARK: - Seal / open

    nonisolated static func seal(_ bundle: ShareBundle, password: String?) throws -> Sealed {
        let plaintext = try bundle.encodeEnvelope()

        let descriptor: Descriptor
        let key: SymmetricKey
        let uploadKey: Data?

        if let password, !password.isEmpty {
            let passwordBytes = Data(password.utf8)
            try validatePasswordBytes(passwordBytes)
            let salt = try randomBytes(saltBytes)
            descriptor = .password(salt: salt, bundleVersion: bundle.v)
            key = SymmetricKey(data: try derivePasswordKey(passwordBytes: passwordBytes, descriptor: descriptor))
            uploadKey = nil
        } else {
            let keyData = try randomBytes(keyBytes)
            descriptor = .codeOnly(bundleVersion: bundle.v)
            key = SymmetricKey(data: keyData)
            uploadKey = keyData
        }

        let aad = try descriptor.canonicalData()
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined,
              combined.count <= maxEncryptedPayloadBytes else {
            throw ShareCryptoError.badPayload
        }
        return Sealed(payload: combined, uploadKey: uploadKey, descriptor: descriptor)
    }

    /// Authenticates the descriptor and payload before parsing the bounded binary envelope.
    nonisolated static func open(
        payload: Data,
        descriptor: Descriptor,
        key: Data?,
        password: String?
    ) throws -> ShareBundle {
        try descriptor.validate()
        guard payload.count >= gcmOverheadBytes,
              payload.count <= maxEncryptedPayloadBytes else {
            throw ShareCryptoError.badPayload
        }

        let symmetric: SymmetricKey
        switch descriptor.tier {
        case .codeOnly:
            guard let key else { throw ShareCryptoError.missingKeyMaterial }
            guard key.count == keyBytes else { throw ShareCryptoError.invalidKeyMaterial }
            symmetric = SymmetricKey(data: key)
        case .password:
            guard key == nil else { throw ShareCryptoError.invalidKeyMaterial }
            guard let password, !password.isEmpty else { throw ShareCryptoError.wrongPassword }
            let passwordBytes = Data(password.utf8)
            try validatePasswordBytes(passwordBytes)
            symmetric = SymmetricKey(
                data: try derivePasswordKey(passwordBytes: passwordBytes, descriptor: descriptor)
            )
        }

        guard let box = try? AES.GCM.SealedBox(combined: payload) else {
            throw ShareCryptoError.badPayload
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: symmetric,
                authenticating: descriptor.canonicalData()
            )
        } catch {
            throw descriptor.tier == .password ? ShareCryptoError.wrongPassword : .badPayload
        }
        let bundle = try ShareBundle.decodeEnvelope(plaintext)
        guard bundle.v == descriptor.bundleVersion else {
            throw ShareCryptoError.invalidDescriptor
        }
        return bundle
    }

    // MARK: - Native PBKDF2

    private nonisolated static func derivePasswordKey(
        passwordBytes: Data,
        descriptor: Descriptor
    ) throws -> Data {
        try descriptor.validate()
        guard descriptor.tier == .password, let salt = descriptor.salt else {
            throw ShareCryptoError.invalidDescriptor
        }
        return try pbkdf2SHA256(
            passwordBytes: passwordBytes,
            salt: salt,
            iterations: descriptor.iterations,
            outputByteCount: keyBytes
        )
    }

    /// Internal so the production smoke harness can verify CommonCrypto against published vectors.
    /// Descriptor validation never permits the low test iteration counts on real shares.
    nonisolated static func pbkdf2SHA256(
        passwordBytes: Data,
        salt: Data,
        iterations: UInt32,
        outputByteCount: Int
    ) throws -> Data {
        guard !passwordBytes.isEmpty,
              !salt.isEmpty,
              iterations > 0,
              outputByteCount > 0,
              outputByteCount <= 64 else {
            throw ShareCryptoError.keyDerivationFailed
        }

        var output = [UInt8](repeating: 0, count: outputByteCount)
        let status: Int32 = passwordBytes.withUnsafeBytes { passwordRaw in
            salt.withUnsafeBytes { saltRaw in
                let passwordPointer = passwordRaw.baseAddress?.assumingMemoryBound(to: Int8.self)
                let saltPointer = saltRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer,
                    passwordBytes.count,
                    saltPointer,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &output,
                    output.count
                )
            }
        }
        guard status == kCCSuccess else { throw ShareCryptoError.keyDerivationFailed }
        return Data(output)
    }

    private nonisolated static func validatePasswordBytes(_ password: Data) throws {
        guard password.count >= minimumPasswordBytes,
              password.count <= maximumPasswordBytes else {
            throw ShareCryptoError.invalidPasswordLength
        }
    }

    private nonisolated static func randomBytes(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ShareCryptoError.randomGenerationFailed
        }
        return Data(bytes)
    }
}
