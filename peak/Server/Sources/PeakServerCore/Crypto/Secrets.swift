import Crypto
import Foundation

/// Random tokens, PKCE, hashing and at-rest encryption. Kept in one place so every secret goes
/// through the same, reviewed code.
public enum Secrets {
    /// URL-safe random string from `byteCount` bytes of system randomness (CSPRNG).
    public static func randomToken(prefix: String = "", byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return prefix + Data(bytes).base64URLEncodedString()
    }

    /// SHA-256, hex. Tokens are stored only as hashes so a database leak doesn't leak sessions.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison for secrets of equal length.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let challenge: String

        /// RFC 7636 S256: 43-char verifier from 32 random bytes; challenge = BASE64URL(SHA256(verifier)).
        public static func generate() -> PKCE {
            let verifier = Secrets.randomToken()
            return PKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        public static func challenge(for verifier: String) -> String {
            Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        }
    }
}

/// AES-256-GCM for Roblox tokens at rest. Nonce is random per seal and stored with the ciphertext.
public struct SecretBox: Sendable {
    private let key: SymmetricKey

    public init(key: Data) throws {
        guard key.count == 32 else { throw SecretBoxError.invalidKeyLength }
        self.key = SymmetricKey(data: key)
    }

    public enum SecretBoxError: Error, Equatable {
        case invalidKeyLength
        case corrupt
    }

    public func seal(_ plaintext: String) throws -> Data {
        guard let combined = try AES.GCM.seal(Data(plaintext.utf8), using: key).combined else {
            throw SecretBoxError.corrupt
        }
        return combined
    }

    public func open(_ sealed: Data) throws -> String {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let data = try AES.GCM.open(box, using: key)
            guard let string = String(data: data, encoding: .utf8) else { throw SecretBoxError.corrupt }
            return string
        } catch {
            throw SecretBoxError.corrupt
        }
    }
}

extension Data {
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
