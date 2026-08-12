import Foundation

/// The user-visible six-digit bearer credential. It remains reusable by any number of recipients
/// until the share expires or its owner revokes it; recipient claim tokens are a server-side detail.
nonisolated struct ShareSessionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    nonisolated init?(rawValue: String) {
        guard rawValue.count == 6,
              rawValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Accepts the two common presentation forms (`123456`, `123 456`, `123-456`) while refusing
    /// labels or other punctuation that could hide an unintended code.
    nonisolated static func parse(_ input: String) -> ShareSessionID? {
        var digits = ""
        digits.reserveCapacity(6)

        for scalar in input.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            switch scalar.value {
            case 48...57:
                guard digits.utf8.count < 6 else { return nil }
                digits.unicodeScalars.append(scalar)
            case 0x20, 0x09, 0x0A, 0x0D, 0x2D, 0x2013, 0x2014:
                continue
            default:
                return nil
            }
        }
        return ShareSessionID(rawValue: digits)
    }

    nonisolated var formatted: String {
        let split = rawValue.index(rawValue.startIndex, offsetBy: 3)
        return "\(rawValue[..<split]) \(rawValue[split...])"
    }

    nonisolated var description: String { rawValue }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = ShareSessionID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A Session ID must contain exactly six ASCII digits."
            )
        }
        self = parsed
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
