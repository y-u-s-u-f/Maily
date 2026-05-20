import XCTest
@testable import MailyCore

final class MessagesGetTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private static func tokenResponse(_ req: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
    }

    func testDefaultFormatBuildsExpectedURL() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.tokenResponse(req) }
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(comps.host, "gmail.googleapis.com")
            XCTAssertEqual(comps.path, "/gmail/v1/users/me/messages/abc123")
            let items = comps.queryItems ?? []
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first, URLQueryItem(name: "format", value: "full"))
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"abc123","threadId":"t1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        let msg = try await client.getMessage(id: "abc123")
        XCTAssertEqual(msg.id, "abc123")
        XCTAssertEqual(msg.threadId, "t1")
    }

    func testMetadataFormatAddsRepeatedMetadataHeaders() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.tokenResponse(req) }
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            let items = comps.queryItems ?? []
            XCTAssertTrue(items.contains(URLQueryItem(name: "format", value: "metadata")))
            let headerValues = items.filter { $0.name == "metadataHeaders" }.compactMap { $0.value }
            XCTAssertEqual(headerValues, ["From", "Subject", "Date"])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"x","threadId":"t"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.getMessage(
            id: "x",
            format: .metadata,
            metadataHeaders: ["From", "Subject", "Date"]
        )
    }

    func testNonMetadataFormatOmitsMetadataHeaders() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.tokenResponse(req) }
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            let items = comps.queryItems ?? []
            XCTAssertFalse(items.contains(where: { $0.name == "metadataHeaders" }))
            XCTAssertEqual(items.first(where: { $0.name == "format" })?.value, "minimal")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"x","threadId":"t"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.getMessage(
            id: "x",
            format: .minimal,
            metadataHeaders: ["From", "Subject"]
        )
    }

    func testDecodesFullMessageWithNestedParts() async throws {
        let json = """
        {
          "id": "18a",
          "threadId": "thr-1",
          "labelIds": ["INBOX", "UNREAD"],
          "snippet": "hello there",
          "historyId": "9876",
          "internalDate": "1715200000000",
          "sizeEstimate": 4321,
          "payload": {
            "mimeType": "multipart/alternative",
            "filename": "",
            "headers": [
              {"name": "From", "value": "alice@example.com"},
              {"name": "Subject", "value": "Hi"}
            ],
            "body": {"size": 0},
            "parts": [
              {
                "mimeType": "text/plain",
                "filename": "",
                "body": {"size": 12, "data": "aGVsbG8gd29ybGQ"}
              },
              {
                "mimeType": "text/html",
                "filename": "",
                "body": {"size": 25, "data": "PGI-aGVsbG88L2I-"}
              }
            ]
          }
        }
        """
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.tokenResponse(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let client = GmailClientTests.makeClient()
        let msg = try await client.getMessage(id: "18a")
        XCTAssertEqual(msg.id, "18a")
        XCTAssertEqual(msg.threadId, "thr-1")
        XCTAssertEqual(msg.labelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(msg.snippet, "hello there")
        XCTAssertEqual(msg.historyId, "9876")
        XCTAssertEqual(msg.internalDate, "1715200000000")
        XCTAssertEqual(msg.sizeEstimate, 4321)
        XCTAssertEqual(msg.payload?.mimeType, "multipart/alternative")
        XCTAssertEqual(msg.payload?.headers?.count, 2)
        XCTAssertEqual(msg.payload?.headers?.first, MessageHeader(name: "From", value: "alice@example.com"))
        XCTAssertEqual(msg.payload?.parts?.count, 2)
        XCTAssertEqual(msg.payload?.parts?[0].mimeType, "text/plain")
        XCTAssertEqual(msg.payload?.parts?[0].body?.data, "aGVsbG8gd29ybGQ")
        XCTAssertEqual(msg.payload?.parts?[1].mimeType, "text/html")
        XCTAssertEqual(msg.payload?.parts?[1].body?.size, 25)
    }

    func testDecodesMinimalResponseWithNilFields() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.tokenResponse(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"m1","threadId":"t1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        let msg = try await client.getMessage(id: "m1", format: .minimal)
        XCTAssertEqual(msg.id, "m1")
        XCTAssertEqual(msg.threadId, "t1")
        XCTAssertNil(msg.labelIds)
        XCTAssertNil(msg.snippet)
        XCTAssertNil(msg.historyId)
        XCTAssertNil(msg.internalDate)
        XCTAssertNil(msg.sizeEstimate)
        XCTAssertNil(msg.payload)
    }

}
