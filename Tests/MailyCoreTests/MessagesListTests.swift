import XCTest
@testable import MailyCore

final class MessagesListTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testListMessagesHitsCorrectPathWithNoParams() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            XCTAssertEqual(req.url?.scheme, "https")
            XCTAssertEqual(req.url?.host, "gmail.googleapis.com")
            XCTAssertEqual(req.url?.path, "/gmail/v1/users/me/messages")
            XCTAssertNil(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = Self.makeClient()
        _ = try await client.listMessages()
    }

    func testListMessagesSerializesQueryParamsIncludingRepeatedLabelIds() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            let items = comps.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "from:alice@example.com is:unread")
            XCTAssertEqual(items.first(where: { $0.name == "maxResults" })?.value, "25")
            XCTAssertEqual(items.first(where: { $0.name == "pageToken" })?.value, "tok-abc")
            XCTAssertEqual(items.first(where: { $0.name == "includeSpamTrash" })?.value, "true")
            let labelValues = items.filter { $0.name == "labelIds" }.map { $0.value ?? "" }
            XCTAssertEqual(labelValues, ["INBOX", "UNREAD"])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = Self.makeClient()
        _ = try await client.listMessages(
            q: "from:alice@example.com is:unread",
            labelIds: ["INBOX", "UNREAD"],
            maxResults: 25,
            pageToken: "tok-abc",
            includeSpamTrash: true
        )
    }

    func testDecodesFullResponse() async throws {
        let json = """
        {
          "messages": [
            {"id": "m1", "threadId": "t1"},
            {"id": "m2", "threadId": "t2"}
          ],
          "nextPageToken": "next-1",
          "resultSizeEstimate": 12345
        }
        """
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let client = Self.makeClient()
        let out = try await client.listMessages()
        XCTAssertEqual(out, MessagesListResponse(
            messages: [
                MessageRef(id: "m1", threadId: "t1"),
                MessageRef(id: "m2", threadId: "t2"),
            ],
            nextPageToken: "next-1",
            resultSizeEstimate: 12345
        ))
    }

    func testDecodesEmptyResponse() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"resultSizeEstimate":0}"#.utf8))
        }
        let client = Self.makeClient()
        let out = try await client.listMessages(q: "label:nope")
        XCTAssertNil(out.messages)
        XCTAssertNil(out.nextPageToken)
        XCTAssertEqual(out.resultSizeEstimate, 0)
    }

    // MARK: - factory

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
