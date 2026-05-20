import XCTest
@testable import MailyCore

final class PKCETests: XCTestCase {

    func testGeneratedVerifierIsURLSafeAndCorrectLength() {
        // RFC 7636 §4.1: verifier is 43..128 chars from [A-Z][a-z][0-9]-._~
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<20 {
            let v = PKCE.generateVerifier()
            XCTAssertGreaterThanOrEqual(v.count, 43)
            XCTAssertLessThanOrEqual(v.count, 128)
            XCTAssertTrue(v.allSatisfy { allowed.contains($0) }, "verifier had disallowed char: \(v)")
        }
    }

    func testGeneratedVerifiersAreUnique() {
        var seen: Set<String> = []
        for _ in 0..<100 {
            seen.insert(PKCE.generateVerifier())
        }
        XCTAssertEqual(seen.count, 100, "expected unique verifiers across 100 generations")
    }

    func testChallengeMatchesRFC7636AppendixBVector() {
        // RFC 7636 Appendix B: known verifier → known SHA256/base64url challenge.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCE.challenge(for: verifier), expected)
    }

    func testChallengeIsURLSafeBase64WithoutPadding() {
        let challenge = PKCE.challenge(for: PKCE.generateVerifier())
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }
}

final class AuthorizationURLTests: XCTestCase {

    private let config = OAuthConfig(
        clientID: "my-client.apps.googleusercontent.com",
        clientSecret: "shh",
        redirectURI: "http://127.0.0.1/oauth/callback"
    )

    func testAuthorizationURLContainsRequiredParameters() throws {
        let url = OAuthFlow.authorizationURL(
            config: config,
            boundRedirectURI: "http://127.0.0.1:54321/oauth/callback",
            scopes: ["https://www.googleapis.com/auth/gmail.modify"],
            state: "state-xyz",
            codeChallenge: "challenge-abc"
        )

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "accounts.google.com")
        XCTAssertEqual(comps.path, "/o/oauth2/v2/auth")

        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "my-client.apps.googleusercontent.com")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:54321/oauth/callback")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/gmail.modify")
        XCTAssertEqual(items["state"], "state-xyz")
        XCTAssertEqual(items["code_challenge"], "challenge-abc")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
    }

    func testAuthorizationURLJoinsMultipleScopesWithSpace() throws {
        let url = OAuthFlow.authorizationURL(
            config: config,
            boundRedirectURI: "http://127.0.0.1:1234/oauth/callback",
            scopes: ["scope.a", "scope.b", "scope.c"],
            state: "s",
            codeChallenge: "c"
        )
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let scope = comps.queryItems!.first { $0.name == "scope" }!.value!
        XCTAssertEqual(scope, "scope.a scope.b scope.c")
    }
}
