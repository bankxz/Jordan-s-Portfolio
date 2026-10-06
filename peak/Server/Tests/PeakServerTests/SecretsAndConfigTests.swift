import Foundation
import Testing
@testable import PeakServerCore

struct SecretsTests {
    @Test func randomTokensAreUniqueURLSafeAndPrefixed() {
        let tokens = (0..<1_000).map { _ in Secrets.randomToken(prefix: "pk_at_") }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            #expect(token.hasPrefix("pk_at_"))
            let body = token.dropFirst("pk_at_".count)
            #expect(body.count == 43)  // 32 bytes, unpadded base64url
            #expect(body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test func pkceMatchesRFC7636AppendixB() {
        // Test vector from RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(Secrets.PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPKCEIsConsistent() {
        let pkce = Secrets.PKCE.generate()
        #expect(pkce.verifier.count == 43)
        #expect(Secrets.PKCE.challenge(for: pkce.verifier) == pkce.challenge)
    }

    @Test func hashIsStableHexSHA256() {
        #expect(Secrets.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Secrets.hash("abc") != Secrets.hash("abd"))
    }

    @Test(arguments: [("abc", "abc", true), ("abc", "abd", false), ("abc", "abcd", false), ("", "", true)])
    func constantTimeEquals(lhs: String, rhs: String, expected: Bool) {
        #expect(Secrets.constantTimeEquals(lhs, rhs) == expected)
    }
}

struct SecretBoxTests {
    let key = Data((0..<32).map { UInt8($0) })

    @Test func roundTripsAndUsesFreshNonces() throws {
        let box = try SecretBox(key: key)
        let a = try box.seal("refresh-token-123")
        let b = try box.seal("refresh-token-123")
        #expect(a != b)
        #expect(try box.open(a) == "refresh-token-123")
        #expect(try box.open(b) == "refresh-token-123")
    }

    @Test func rejectsWrongKeyAndTampering() throws {
        let sealed = try SecretBox(key: key).seal("secret")
        let other = try SecretBox(key: Data(repeating: 7, count: 32))
        #expect(throws: SecretBox.SecretBoxError.corrupt) { try other.open(sealed) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: SecretBox.SecretBoxError.corrupt) { try SecretBox(key: key).open(tampered) }
        #expect(throws: SecretBox.SecretBoxError.corrupt) { try SecretBox(key: key).open(Data([1, 2, 3])) }
    }

    @Test(arguments: [0, 16, 31, 33, 64])
    func rejectsWrongKeyLength(length: Int) {
        #expect(throws: SecretBox.SecretBoxError.invalidKeyLength) { try SecretBox(key: Data(count: length)) }
    }
}

struct ServerConfigTests {
    static let base: [String: String] = [
        "ROBLOX_CLIENT_ID": "123",
        "ROBLOX_CLIENT_SECRET": "RBX-secret",
        "ROBLOX_REDIRECT_URI": "https://api.peakstats.app/oauth/roblox/callback",
        "TOKEN_ENCRYPTION_KEY": Data(repeating: 1, count: 32).base64EncodedString(),
    ]

    @Test func parsesMinimalEnvironment() throws {
        let config = try ServerConfig.fromEnvironment(Self.base)
        #expect(config.port == 8080)
        #expect(config.databaseURL == nil)
        #expect(config.apns == nil)
        #expect(config.roblox.scopes == ["openid", "profile", "universe.analytics:read"])
        #expect(config.appCallbackURL.absoluteString == "peakstats://auth/complete")
    }

    @Test func descriptionNeverContainsSecrets() throws {
        var env = Self.base
        env["APNS_PRIVATE_KEY"] = "-----BEGIN PRIVATE KEY-----abc"
        env["APNS_TEAM_ID"] = "TEAM"
        env["APNS_KEY_ID"] = "KEY"
        let text = try ServerConfig.fromEnvironment(env).description
        #expect(text.contains("RBX-secret") == false)
        #expect(text.contains(Self.base["TOKEN_ENCRYPTION_KEY"]!) == false)
        #expect(text.contains("BEGIN PRIVATE KEY") == false)
    }

    @Test(arguments: ["ROBLOX_CLIENT_ID", "ROBLOX_CLIENT_SECRET", "ROBLOX_REDIRECT_URI", "TOKEN_ENCRYPTION_KEY"])
    func missingRequiredKey(key: String) {
        var env = Self.base
        env[key] = nil
        #expect(throws: ServerConfig.ConfigError.missing(key)) { try ServerConfig.fromEnvironment(env) }
    }

    @Test(arguments: [
        ("TOKEN_ENCRYPTION_KEY", "c2hvcnQ="),
        ("TOKEN_ENCRYPTION_KEY", "not base64!"),
        ("ROBLOX_REDIRECT_URI", "http://example.com/callback"),
        ("PORT", "0"),
        ("PORT", "http"),
    ])
    func invalidValues(key: String, value: String) {
        var env = Self.base
        env[key] = value
        #expect(throws: ServerConfig.ConfigError.self) { try ServerConfig.fromEnvironment(env) }
    }

    @Test func aiIsOffWithoutAKeyAndConfiguredWithOne() throws {
        #expect(try ServerConfig.fromEnvironment(Self.base).ai == nil)
        var env = Self.base
        env["ANTHROPIC_API_KEY"] = "sk-ant-secret-value"
        env["PEAK_AI_MODEL_ASK"] = "claude-sonnet-5-5"
        env["PEAK_AI_MONTHLY_BUDGET_USD"] = "10"
        let config = try ServerConfig.fromEnvironment(env)
        let ai = try #require(config.ai)
        #expect(ai.model == "claude-opus-5-5")
        #expect(ai.askModel == "claude-sonnet-5-5")
        #expect(ai.briefingModel == nil)
        #expect(ai.dailyAskLimit == 20)
        let settings = AIService.Settings(ai)
        #expect(settings.briefingModel == "claude-opus-5-5")
        #expect(settings.monthlyBudgetMicros == 10_000_000)
        #expect(config.description.contains("sk-ant-secret-value") == false)
        #expect(config.description.contains("claude-opus-5-5"))

        env["PEAK_AI_MONTHLY_BUDGET_USD"] = "-1"
        #expect(throws: ServerConfig.ConfigError.self) { try ServerConfig.fromEnvironment(env) }
    }

    @Test func apnsNeedsTeamAndKeyIDs() {
        var env = Self.base
        env["APNS_PRIVATE_KEY"] = "pem"
        #expect(throws: ServerConfig.ConfigError.missing("APNS_TEAM_ID")) { try ServerConfig.fromEnvironment(env) }
    }
}
