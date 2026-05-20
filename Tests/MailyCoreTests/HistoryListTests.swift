import XCTest
@testable import MailyCore

final class HistoryListTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testListHistoryURLWithOnlyStartHistoryId() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            XCTAssertEqual(req.url?.scheme, "https")
            XCTAssertEqual(req.url?.host, "gmail.googleapis.com")
            XCTAssertEqual(req.url?.path, "/gmail/v1/users/me/history")
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            let items = comps.queryItems ?? []
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.name, "startHistoryId")
            XCTAssertEqual(items.first?.value, "12345")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.listHistory(startHistoryId: "12345")
    }

    func testListHistoryEncodesAllOptionalParams() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            let items = comps.queryItems ?? []
            XCTAssertEqual(items.filter { $0.name == "startHistoryId" }.map { $0.value }, ["999"])
            XCTAssertEqual(items.filter { $0.name == "labelId" }.map { $0.value }, ["INBOX"])
            XCTAssertEqual(
                items.filter { $0.name == "historyTypes" }.compactMap { $0.value },
                ["messageAdded", "labelAdded", "labelRemoved"]
            )
            XCTAssertEqual(items.filter { $0.name == "pageToken" }.map { $0.value }, ["pt-xyz"])
            XCTAssertEqual(items.filter { $0.name == "maxResults" }.map { $0.value }, ["250"])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = GmailClientTests.makeClient()
        _ = try await client.listHistory(
            startHistoryId: "999",
            labelId: "INBOX",
            historyTypes: ["messageAdded", "labelAdded", "labelRemoved"],
            pageToken: "pt-xyz",
            maxResults: 250
        )
    }

    func testDecodesFullHistoryResponse() async throws {
        let payload = """
        {
          "history": [
            {
              "id": "100",
              "messages": [{"id":"m1","threadId":"t1"}],
              "messagesAdded": [
                {"message":{"id":"m1","threadId":"t1","labelIds":["INBOX"]}}
              ],
              "messagesDeleted": [
                {"message":{"id":"m2","threadId":"t2"}}
              ],
              "labelsAdded": [
                {"message":{"id":"m3","threadId":"t3"},"labelIds":["STARRED"]}
              ],
              "labelsRemoved": [
                {"message":{"id":"m4","threadId":"t4"},"labelIds":["UNREAD"]}
              ]
            }
          ],
          "nextPageToken": "next",
          "historyId": "200"
        }
        """
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8))
        }
        let client = GmailClientTests.makeClient()
        let resp = try await client.listHistory(startHistoryId: "100")
        XCTAssertEqual(resp.nextPageToken, "next")
        XCTAssertEqual(resp.historyId, "200")
        XCTAssertEqual(resp.history?.count, 1)
        let entry = resp.history?.first
        XCTAssertEqual(entry?.id, "100")
        XCTAssertEqual(entry?.messages, [HistoryMessageRef(id: "m1", threadId: "t1")])
        XCTAssertEqual(
            entry?.messagesAdded,
            [HistoryMessageMutation(message: HistoryMessageRef(id: "m1", threadId: "t1"), labelIds: nil)]
        )
        XCTAssertEqual(
            entry?.messagesDeleted,
            [HistoryMessageMutation(message: HistoryMessageRef(id: "m2", threadId: "t2"), labelIds: nil)]
        )
        XCTAssertEqual(
            entry?.labelsAdded,
            [HistoryMessageMutation(message: HistoryMessageRef(id: "m3", threadId: "t3"), labelIds: ["STARRED"])]
        )
        XCTAssertEqual(
            entry?.labelsRemoved,
            [HistoryMessageMutation(message: HistoryMessageRef(id: "m4", threadId: "t4"), labelIds: ["UNREAD"])]
        )
    }

    func testDecodesEmptyHistoryResponse() async throws {
        let payload = #"{"historyId":"500"}"#
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8))
        }
        let client = GmailClientTests.makeClient()
        let resp = try await client.listHistory(startHistoryId: "500")
        XCTAssertNil(resp.history)
        XCTAssertNil(resp.nextPageToken)
        XCTAssertEqual(resp.historyId, "500")
    }

    func testExpiredHistoryIdSurfacesAs404() async throws {
        let body = Data(#"{"error":{"code":404,"message":"Requested entity was not found."}}"#.utf8)
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = GmailClientTests.makeClient()
        do {
            _ = try await client.listHistory(startHistoryId: "expired-id")
            XCTFail("expected 404 to throw")
        } catch let AuthenticatedSessionError.http(status, returnedBody) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(returnedBody, body)
        } catch {
            XCTFail("expected AuthenticatedSessionError.http(404, ...), got \(error)")
        }
    }
}
