import XCTest
@testable import MailyCore

final class BatchTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func tokenResponse(_ req: URLRequest) -> (HTTPURLResponse, Data)? {
        guard req.url?.host == "oauth2.googleapis.com" else { return nil }
        let body = Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    /// Build a multipart/mixed response body with the given embedded HTTP
    /// responses, in the same shape Gmail returns for `/batch/gmail/v1`.
    private func makeBatchResponseBody(boundary: String, parts: [(status: Int, reason: String, headers: [(String, String)], body: String)]) -> Data {
        var out = ""
        for part in parts {
            out += "--\(boundary)\r\n"
            out += "Content-Type: application/http\r\n"
            out += "\r\n"
            out += "HTTP/1.1 \(part.status) \(part.reason)\r\n"
            for (k, v) in part.headers {
                out += "\(k): \(v)\r\n"
            }
            out += "\r\n"
            out += part.body
            out += "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    // MARK: - request encoding

    func testThreeGETsRoundTrip() async throws {
        let responseBoundary = "resp-boundary-abc"
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }

            // Outer request shape
            XCTAssertEqual(req.url?.absoluteString, "https://gmail.googleapis.com/batch/gmail/v1")
            XCTAssertEqual(req.httpMethod, "POST")
            let ct = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(ct.hasPrefix("multipart/mixed; boundary="), "got: \(ct)")
            let reqBoundary = String(ct.dropFirst("multipart/mixed; boundary=".count))
            XCTAssertTrue(reqBoundary.hasPrefix("maily-batch-"))

            let bodyString = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""

            // Three outer parts, one closing delimiter.
            let openCount = bodyString.components(separatedBy: "--\(reqBoundary)\r\n").count - 1
            XCTAssertEqual(openCount, 3, "expected 3 opening delimiters, body was:\n\(bodyString)")
            XCTAssertTrue(bodyString.hasSuffix("--\(reqBoundary)--\r\n"))

            // Each part has Content-Type: application/http and embedded GET line.
            XCTAssertTrue(bodyString.contains("Content-Type: application/http\r\n"))
            XCTAssertTrue(bodyString.contains("GET /gmail/v1/users/me/messages/a?format=metadata HTTP/1.1\r\n"))
            XCTAssertTrue(bodyString.contains("GET /gmail/v1/users/me/messages/b?format=metadata HTTP/1.1\r\n"))
            XCTAssertTrue(bodyString.contains("GET /gmail/v1/users/me/messages/c?format=metadata HTTP/1.1\r\n"))

            let respBody = self.makeBatchResponseBody(boundary: responseBoundary, parts: [
                (200, "OK", [("Content-Type", "application/json")], #"{"id":"a"}"#),
                (200, "OK", [("Content-Type", "application/json")], #"{"id":"b"}"#),
                (200, "OK", [("Content-Type", "application/json")], #"{"id":"c"}"#),
            ])
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(responseBoundary)"]
            )!
            return (resp, respBody)
        }

        let client = GmailClientTests.makeClient()
        let subs = ["a", "b", "c"].map {
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/\($0)?format=metadata")
        }
        let out = try await client.batch(subs)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].status, 200)
        XCTAssertEqual(String(data: out[0].body, encoding: .utf8), #"{"id":"a"}"#)
        XCTAssertEqual(String(data: out[1].body, encoding: .utf8), #"{"id":"b"}"#)
        XCTAssertEqual(String(data: out[2].body, encoding: .utf8), #"{"id":"c"}"#)
        XCTAssertEqual(out[0].headers["Content-Type"], "application/json")
    }

    func testMixedGETAndPOSTSerializesBodyAndContentLength() async throws {
        let responseBoundary = "rb-mixed"
        let postBodyBytes = Data(#"{"addLabelIds":["STARRED"],"removeLabelIds":[]}"#.utf8)

        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }

            let ct = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            let reqBoundary = String(ct.dropFirst("multipart/mixed; boundary=".count))
            let bodyString = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""

            // GET part is body-less.
            XCTAssertTrue(bodyString.contains("GET /gmail/v1/users/me/messages/m1 HTTP/1.1\r\n"))

            // POST part carries Content-Type, Content-Length, and the JSON body.
            XCTAssertTrue(bodyString.contains("POST /gmail/v1/users/me/threads/t1/modify HTTP/1.1\r\n"))
            XCTAssertTrue(bodyString.contains("Content-Type: application/json\r\n"))
            XCTAssertTrue(bodyString.contains("Content-Length: \(postBodyBytes.count)\r\n"))
            XCTAssertTrue(bodyString.contains(#""addLabelIds":["STARRED"]"#))

            // Ordering: GET part comes before POST part.
            let getRange = bodyString.range(of: "GET /gmail/v1/users/me/messages/m1")!
            let postRange = bodyString.range(of: "POST /gmail/v1/users/me/threads/t1/modify")!
            XCTAssertLessThan(getRange.lowerBound, postRange.lowerBound)

            // Closing delimiter present.
            XCTAssertTrue(bodyString.hasSuffix("--\(reqBoundary)--\r\n"))

            let respBody = self.makeBatchResponseBody(boundary: responseBoundary, parts: [
                (200, "OK", [("Content-Type", "application/json")], #"{"id":"m1"}"#),
                (200, "OK", [("Content-Type", "application/json")], #"{"id":"t1"}"#),
            ])
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(responseBoundary)"]
            )!
            return (resp, respBody)
        }

        let client = GmailClientTests.makeClient()
        let out = try await client.batch([
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/m1"),
            BatchSubrequest(
                method: "POST",
                path: "/gmail/v1/users/me/threads/t1/modify",
                body: postBodyBytes,
                contentType: "application/json"
            ),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].status, 200)
        XCTAssertEqual(out[1].status, 200)
        XCTAssertEqual(String(data: out[1].body, encoding: .utf8), #"{"id":"t1"}"#)
    }

    func testResponseOrderMatchesRequestOrder() async throws {
        let responseBoundary = "rb-order"
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            let respBody = self.makeBatchResponseBody(boundary: responseBoundary, parts: [
                (200, "OK", [], "first"),
                (200, "OK", [], "second"),
                (200, "OK", [], "third"),
            ])
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(responseBoundary)"]
            )!
            return (resp, respBody)
        }
        let client = GmailClientTests.makeClient()
        let out = try await client.batch([
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/x"),
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/y"),
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/z"),
        ])
        XCTAssertEqual(out.map { String(data: $0.body, encoding: .utf8) }, ["first", "second", "third"])
    }

    func testSubresponseNon200StatusSurfaces() async throws {
        let responseBoundary = "rb-mixed-status"
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            let respBody = self.makeBatchResponseBody(boundary: responseBoundary, parts: [
                (200, "OK", [("Content-Type", "application/json")], #"{"id":"ok"}"#),
                (404, "Not Found", [("Content-Type", "application/json")], #"{"error":"missing"}"#),
            ])
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(responseBoundary)"]
            )!
            return (resp, respBody)
        }
        let client = GmailClientTests.makeClient()
        let out = try await client.batch([
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/ok"),
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/gone"),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].status, 200)
        XCTAssertEqual(out[1].status, 404)
        XCTAssertEqual(String(data: out[1].body, encoding: .utf8), #"{"error":"missing"}"#)
    }

    func testEmptyBatchThrows() async throws {
        let client = GmailClientTests.makeClient()
        do {
            _ = try await client.batch([])
            XCTFail("expected throw")
        } catch BatchError.empty {
            // ok
        }
    }

    func testMoreThan100Throws() async throws {
        let client = GmailClientTests.makeClient()
        let subs = (0..<101).map {
            BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/m\($0)")
        }
        do {
            _ = try await client.batch(subs)
            XCTFail("expected throw")
        } catch BatchError.tooManySubrequests(let n) {
            XCTAssertEqual(n, 101)
        }
    }

    func testMissingResponseContentTypeThrows() async throws {
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            // No Content-Type header on the response.
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (resp, Data("garbage".utf8))
        }
        let client = GmailClientTests.makeClient()
        do {
            _ = try await client.batch([
                BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/a"),
            ])
            XCTFail("expected throw")
        } catch BatchError.missingBoundary {
            // ok
        }
    }

    func testFewerSubresponsesThanRequestsThrows() async throws {
        let responseBoundary = "rb-short"
        StubURLProtocol.handler = { req in
            if let t = self.tokenResponse(req) { return t }
            // Two requests, but only one response part.
            let respBody = self.makeBatchResponseBody(boundary: responseBoundary, parts: [
                (200, "OK", [], "only one"),
            ])
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(responseBoundary)"]
            )!
            return (resp, respBody)
        }
        let client = GmailClientTests.makeClient()
        do {
            _ = try await client.batch([
                BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/a"),
                BatchSubrequest(method: "GET", path: "/gmail/v1/users/me/messages/b"),
            ])
            XCTFail("expected throw")
        } catch BatchError.subresponseCountMismatch(let expected, let got) {
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(got, 1)
        }
    }
}
