import XCTest
@testable import MailyCore

final class GmailClientTests: XCTestCase {

    private let config = OAuthConfig(
        clientID: "c", clientSecret: "s",
        redirectURI: "http://127.0.0.1/oauth/callback"
    )

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testBuildsURLAgainstUserBasePath() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                let body = Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            XCTAssertEqual(
                req.url?.absoluteString,
                "https://gmail.googleapis.com/gmail/v1/users/me/labels"
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = Self.makeClient()
        _ = try await client.get("labels", queryItems: [])
    }

    func testQueryItemsArePercentEncoded() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(q["q"], "from:alice@example.com is:unread")
            XCTAssertEqual(q["maxResults"], "50")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = Self.makeClient()
        _ = try await client.get("messages", queryItems: [
            URLQueryItem(name: "q", value: "from:alice@example.com is:unread"),
            URLQueryItem(name: "maxResults", value: "50"),
        ])
    }

    func testPostJSONSendsBodyAndContentType() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(json?["foo"] as? String, "bar")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = Self.makeClient()
        _ = try await client.post("threads/abc/modify", json: ["foo": "bar"])
    }

    func testDecodesTypedResponse() async throws {
        struct Out: Decodable, Equatable { let name: String; let count: Int }
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"name":"inbox","count":42}"#.utf8))
        }
        let client = Self.makeClient()
        let out: Out = try await client.getJSON("labels/INBOX", queryItems: [])
        XCTAssertEqual(out, Out(name: "inbox", count: 42))
    }

    // MARK: - shared factory

    static func makeClient() -> GmailClient {
        let store = InMemoryTokenStore()
        try? store.saveRefreshToken("rt", account: "a@example.com")
        let urlSession = URLSession.stubbed()
        let endpoint = TokenEndpoint(
            config: OAuthConfig(clientID: "c", clientSecret: "s", redirectURI: "http://127.0.0.1/cb"),
            session: urlSession
        )
        let auth = AuthenticatedSession(
            account: "a@example.com",
            tokenStore: store,
            tokenEndpoint: endpoint,
            session: urlSession,
            sleeper: { _ in }
        )
        return GmailClient(session: auth, userID: "me")
    }
}
