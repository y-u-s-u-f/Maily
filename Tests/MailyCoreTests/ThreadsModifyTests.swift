import XCTest
@testable import MailyCore

final class ThreadsModifyTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func tokenResponse(_ req: URLRequest) -> (HTTPURLResponse, Data)? {
        guard req.url?.host == "oauth2.googleapis.com" else { return nil }
        let body = Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    func testURLPathIncludesThreadID() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            XCTAssertEqual(
                req.url?.absoluteString,
                "https://gmail.googleapis.com/gmail/v1/users/me/threads/abc123/modify"
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"abc123"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.modifyThread(id: "abc123", addLabelIds: [], removeLabelIds: ["UNREAD"])
    }

    func testContentTypeIsJSON() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.modifyThread(id: "t1", addLabelIds: ["STARRED"], removeLabelIds: [])
    }

    func testBodyContainsBothLabelArrays() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(json?["addLabelIds"] as? [String], ["STARRED", "IMPORTANT"])
            XCTAssertEqual(json?["removeLabelIds"] as? [String], ["UNREAD", "INBOX"])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.modifyThread(
            id: "t1",
            addLabelIds: ["STARRED", "IMPORTANT"],
            removeLabelIds: ["UNREAD", "INBOX"]
        )
    }

    func testDecodesFullThreadResponse() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            let body = Data(#"""
            {
              "id": "thr1",
              "snippet": "hello there",
              "historyId": "98765",
              "messages": [
                {"id": "m1", "threadId": "thr1"},
                {"id": "m2", "threadId": "thr1"}
              ]
            }
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = GmailClientTests.makeClient()
        let thread = try await client.modifyThread(id: "thr1", addLabelIds: [], removeLabelIds: ["UNREAD"])
        XCTAssertEqual(thread.id, "thr1")
        XCTAssertEqual(thread.snippet, "hello there")
        XCTAssertEqual(thread.historyId, "98765")
        XCTAssertEqual(thread.messages, [
            ThreadMessageRef(id: "m1", threadId: "thr1"),
            ThreadMessageRef(id: "m2", threadId: "thr1"),
        ])
    }

    func testEmptyArraysStillSerializeBothKeys() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertNotNil(json)
            XCTAssertNotNil(json?["addLabelIds"], "addLabelIds key must be present even when empty")
            XCTAssertNotNil(json?["removeLabelIds"], "removeLabelIds key must be present even when empty")
            XCTAssertEqual(json?["addLabelIds"] as? [String], [])
            XCTAssertEqual(json?["removeLabelIds"] as? [String], [])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.modifyThread(id: "t1")
    }

    func testDecodesMinimalThreadResponse() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"only"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        let thread = try await client.modifyThread(id: "only", addLabelIds: ["STARRED"], removeLabelIds: [])
        XCTAssertEqual(thread.id, "only")
        XCTAssertNil(thread.snippet)
        XCTAssertNil(thread.historyId)
        XCTAssertNil(thread.messages)
    }
}
