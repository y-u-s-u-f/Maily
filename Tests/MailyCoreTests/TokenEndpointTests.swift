import XCTest
@testable import MailyCore

final class TokenEndpointTests: XCTestCase {

    private let config = OAuthConfig(
        clientID: "client-123.apps.googleusercontent.com",
        clientSecret: "the-secret",
        redirectURI: "http://127.0.0.1:54321/oauth/callback"
    )

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Code exchange

    func testExchangeCodePostsExpectedFormBody() async throws {
        StubURLProtocol.handler = { _ in
            let body = """
            {
              "access_token": "ya29.abc",
              "expires_in": 3599,
              "refresh_token": "1//rt",
              "scope": "https://www.googleapis.com/auth/gmail.modify",
              "token_type": "Bearer"
            }
            """
            return (
                HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!,
                                statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let endpoint = TokenEndpoint(config: config, session: .stubbed())
        let token = try await endpoint.exchangeCode(
            "auth-code-xyz",
            codeVerifier: "verifier-abc",
            boundRedirectURI: "http://127.0.0.1:54321/oauth/callback"
        )

        XCTAssertEqual(token.accessToken, "ya29.abc")
        XCTAssertEqual(token.refreshToken, "1//rt")
        XCTAssertEqual(token.expiresIn, 3599)
        XCTAssertEqual(token.scope, "https://www.googleapis.com/auth/gmail.modify")

        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let req = StubURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

        let bodyString = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        let params = Self.parseFormBody(bodyString)
        XCTAssertEqual(params["grant_type"], "authorization_code")
        XCTAssertEqual(params["code"], "auth-code-xyz")
        XCTAssertEqual(params["code_verifier"], "verifier-abc")
        XCTAssertEqual(params["client_id"], "client-123.apps.googleusercontent.com")
        XCTAssertEqual(params["client_secret"], "the-secret")
        XCTAssertEqual(params["redirect_uri"], "http://127.0.0.1:54321/oauth/callback")
    }

    func testExchangeCodeFormEncodesSpecialCharacters() async throws {
        StubURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"access_token":"a","expires_in":1,"refresh_token":"r","scope":"s","token_type":"Bearer"}"#.utf8))
        }
        let endpoint = TokenEndpoint(config: config, session: .stubbed())
        _ = try await endpoint.exchangeCode(
            "code with spaces & ampersands",
            codeVerifier: "v",
            boundRedirectURI: "http://127.0.0.1:1/cb"
        )

        let body = String(data: StubURLProtocol.capturedRequests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("code=code%20with%20spaces%20%26%20ampersands"),
                      "expected percent-encoding, got: \(body)")
    }

    func testExchangeCodeThrowsOnNon2xx() async {
        StubURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "x")!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"invalid_grant","error_description":"bad code"}"#.utf8))
        }
        let endpoint = TokenEndpoint(config: config, session: .stubbed())
        do {
            _ = try await endpoint.exchangeCode(
                "bad", codeVerifier: "v",
                boundRedirectURI: "http://127.0.0.1:1/cb"
            )
            XCTFail("expected throw")
        } catch let error as TokenEndpointError {
            guard case .oauthError(let code, _, let status) = error else {
                return XCTFail("expected .oauthError, got \(error)")
            }
            XCTAssertEqual(code, "invalid_grant")
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Refresh

    func testRefreshPostsExpectedFormBodyAndKeepsExistingRefreshToken() async throws {
        StubURLProtocol.handler = { _ in
            let body = """
            {
              "access_token": "ya29.fresh",
              "expires_in": 3599,
              "scope": "https://www.googleapis.com/auth/gmail.modify",
              "token_type": "Bearer"
            }
            """
            return (
                HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!,
                                statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let endpoint = TokenEndpoint(config: config, session: .stubbed())
        let token = try await endpoint.refresh(refreshToken: "1//rt-existing")

        XCTAssertEqual(token.accessToken, "ya29.fresh")
        XCTAssertEqual(token.expiresIn, 3599)
        // Google omits refresh_token on refresh — the caller is expected to
        // keep using the one they had.
        XCTAssertNil(token.refreshToken)

        let body = String(data: StubURLProtocol.capturedRequests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        let params = Self.parseFormBody(body)
        XCTAssertEqual(params["grant_type"], "refresh_token")
        XCTAssertEqual(params["refresh_token"], "1//rt-existing")
        XCTAssertEqual(params["client_id"], "client-123.apps.googleusercontent.com")
        XCTAssertEqual(params["client_secret"], "the-secret")
    }

    func testRefreshSurfacesInvalidGrant() async {
        StubURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "x")!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))
        }
        let endpoint = TokenEndpoint(config: config, session: .stubbed())
        do {
            _ = try await endpoint.refresh(refreshToken: "stale")
            XCTFail("expected throw")
        } catch let error as TokenEndpointError {
            guard case .oauthError(let code, _, _) = error else {
                return XCTFail("expected .oauthError, got \(error)")
            }
            XCTAssertEqual(code, "invalid_grant")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - helpers

    private static func parseFormBody(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts[1].removingPercentEncoding ?? parts[1]
            out[key] = value
        }
        return out
    }
}
