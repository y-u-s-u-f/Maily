import XCTest
import GRDB
@testable import MailyCore

// Thread-safe accumulator usable in @Sendable test closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func append(_ value: Int) { lock.withLock { _values.append(value) } }
}

final class MetadataBatchSyncerTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func tokenResponse(_ req: URLRequest) -> (HTTPURLResponse, Data)? {
        guard req.url?.host == "oauth2.googleapis.com" else { return nil }
        let body = Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    /// Build a multipart/mixed response body matching Gmail's `/batch/gmail/v1` shape.
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

    /// JSON for one GmailMessage suitable for an embedded subresponse body.
    private func gmailMessageJSON(
        id: String,
        threadId: String,
        snippet: String? = nil,
        labelIds: [String]? = nil,
        internalDate: String? = nil,
        headers: [(String, String)] = []
    ) -> String {
        var obj: [String: Any] = ["id": id, "threadId": threadId]
        if let snippet { obj["snippet"] = snippet }
        if let labelIds { obj["labelIds"] = labelIds }
        if let internalDate { obj["internalDate"] = internalDate }
        if !headers.isEmpty {
            obj["payload"] = ["headers": headers.map { ["name": $0.0, "value": $0.1] }]
        }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeDB() throws -> MailyDatabase {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct-1", email: "u@x").insert($0) }
        return db
    }

    // MARK: - Test 1: single chunk of 3 messages → 3 rows + threads auto-created

    func testSingleChunkInsertsMessagesAndThreads() async throws {
        let respBoundary = "rb1"
        StubURLProtocol.handler = { [self] req in
            if let t = self.tokenResponse(req) { return t }
            let parts: [(Int, String, [(String, String)], String)] = [
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: "m1", threadId: "t1", snippet: "s1", labelIds: ["INBOX"], internalDate: "1700000000000")),
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: "m2", threadId: "t1", snippet: "s2", labelIds: ["INBOX", "UNREAD"], internalDate: "1700000001000")),
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: "m3", threadId: "t2", snippet: "s3", labelIds: ["INBOX"], internalDate: "1700000002000")),
            ]
            let body = self.makeBatchResponseBody(boundary: respBoundary, parts: parts)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(respBoundary)"]
            )!
            return (resp, body)
        }

        let db = try makeDB()
        let counts = Counter()
        let syncer = MetadataBatchSyncer(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1",
            onChunk: { counts.append($0) }
        )
        let refs = [
            MessageRef(id: "m1", threadId: "t1"),
            MessageRef(id: "m2", threadId: "t1"),
            MessageRef(id: "m3", threadId: "t2"),
        ]
        try await syncer.sync(refs)

        let (messageCount, threadIDs) = try await db.queue.read { db -> (Int, Set<String>) in
            let mc = try Message.fetchCount(db)
            let ids = try MailThread.fetchAll(db).map(\.id)
            return (mc, Set(ids))
        }
        XCTAssertEqual(messageCount, 3)
        XCTAssertEqual(threadIDs, ["t1", "t2"])
        XCTAssertEqual(counts.values, [3])
    }

    // MARK: - Test 2: 101 messages → 2 HTTP calls

    func testTwoChunksProduceTwoBatchHTTPCalls() async throws {
        let respBoundary = "rb2"
        StubURLProtocol.handler = { [self] req in
            if let t = self.tokenResponse(req) { return t }
            // Parse boundary from request to know how many subrequests there are.
            // We just need to return one subresponse per request. Decode body to count parts.
            let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            let reqCT = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            let reqBoundary = String(reqCT.dropFirst("multipart/mixed; boundary=".count))
            // Count opening delimiters (one per subrequest).
            let n = bodyStr.components(separatedBy: "--\(reqBoundary)\r\n").count - 1

            // Extract message ids from the request paths to keep responses aligned.
            // Path lines look like: GET /gmail/v1/users/me/messages/<id>?format=metadata...
            var ids: [String] = []
            let lines = bodyStr.components(separatedBy: "\r\n")
            for line in lines where line.hasPrefix("GET /gmail/v1/users/me/messages/") {
                let rest = line.dropFirst("GET /gmail/v1/users/me/messages/".count)
                if let qIdx = rest.firstIndex(of: "?") {
                    ids.append(String(rest[..<qIdx]))
                }
            }
            XCTAssertEqual(ids.count, n)

            let parts: [(Int, String, [(String, String)], String)] = ids.map { id in
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: id, threadId: "t-\(id)", snippet: "s-\(id)",
                                        labelIds: ["INBOX"], internalDate: "1700000000000"))
            }
            let body = self.makeBatchResponseBody(boundary: respBoundary, parts: parts)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(respBoundary)"]
            )!
            return (resp, body)
        }

        let db = try makeDB()
        let syncer = MetadataBatchSyncer(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1"
        )
        let refs = (0..<101).map { MessageRef(id: "m\($0)", threadId: "t-m\($0)") }
        try await syncer.sync(refs)

        let batchCalls = StubURLProtocol.capturedRequests.filter {
            $0.url?.absoluteString.contains("/batch/gmail/v1") == true
        }.count
        XCTAssertEqual(batchCalls, 2)

        let messageCount = try await db.queue.read { try Message.fetchCount($0) }
        XCTAssertEqual(messageCount, 101)
    }

    // MARK: - Test 3: duplicate ids across chunks → second write wins

    func testDuplicateIdsAcrossChunksSecondWriteWins() async throws {
        let respBoundary = "rb3"
        let callCounter = Counter()
        StubURLProtocol.handler = { [self] req in
            if let t = self.tokenResponse(req) { return t }
            let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            let reqCT = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            let reqBoundary = String(reqCT.dropFirst("multipart/mixed; boundary=".count))

            // Extract ids from paths.
            var ids: [String] = []
            for line in bodyStr.components(separatedBy: "\r\n") where line.hasPrefix("GET /gmail/v1/users/me/messages/") {
                let rest = line.dropFirst("GET /gmail/v1/users/me/messages/".count)
                if let qIdx = rest.firstIndex(of: "?") {
                    ids.append(String(rest[..<qIdx]))
                }
            }

            let callIndex = callCounter.values.count
            callCounter.append(callIndex)

            // First call: From=alice. Second call: From=bob (so we can verify second wins for dup).
            let fromValue = callIndex == 0 ? "alice@example.com" : "bob@example.com"
            let parts: [(Int, String, [(String, String)], String)] = ids.map { id in
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: id, threadId: "t-\(id)", snippet: "s-\(id)",
                                        labelIds: ["INBOX"], internalDate: "1700000000000",
                                        headers: [("From", fromValue)]))
            }
            _ = reqBoundary
            let body = self.makeBatchResponseBody(boundary: respBoundary, parts: parts)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(respBoundary)"]
            )!
            return (resp, body)
        }

        let db = try makeDB()
        let syncer = MetadataBatchSyncer(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1",
            chunkSize: 2
        )
        // chunk1: a, dup ; chunk2: dup, b — same id "dup" appears in both chunks.
        let refs = [
            MessageRef(id: "a", threadId: "ta"),
            MessageRef(id: "dup", threadId: "tdup"),
            MessageRef(id: "dup", threadId: "tdup"),
            MessageRef(id: "b", threadId: "tb"),
        ]
        try await syncer.sync(refs)

        let dupRow = try await db.queue.read { try Message.fetchOne($0, key: "dup") }
        XCTAssertNotNil(dupRow)
        // Second chunk wrote bob — second write wins.
        XCTAssertEqual(dupRow?.fromAddr, "bob@example.com")

        let messageCount = try await db.queue.read { try Message.fetchCount($0) }
        XCTAssertEqual(messageCount, 3) // a, dup, b
    }

    // MARK: - Test 4: 404 subresponse skipped, neighbors still inserted

    func testSubresponse404SkippedNeighborsInserted() async throws {
        let respBoundary = "rb4"
        StubURLProtocol.handler = { [self] req in
            if let t = self.tokenResponse(req) { return t }
            let parts: [(Int, String, [(String, String)], String)] = [
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: "ok1", threadId: "tk1", snippet: "s1",
                                        labelIds: ["INBOX"], internalDate: "1700000000000")),
                (404, "Not Found", [("Content-Type", "application/json")], #"{"error":"missing"}"#),
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(id: "ok2", threadId: "tk2", snippet: "s2",
                                        labelIds: ["INBOX"], internalDate: "1700000002000")),
            ]
            let body = self.makeBatchResponseBody(boundary: respBoundary, parts: parts)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(respBoundary)"]
            )!
            return (resp, body)
        }

        let db = try makeDB()
        let counts = Counter()
        let syncer = MetadataBatchSyncer(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1",
            onChunk: { counts.append($0) }
        )
        let refs = [
            MessageRef(id: "ok1", threadId: "tk1"),
            MessageRef(id: "gone", threadId: "tg"),
            MessageRef(id: "ok2", threadId: "tk2"),
        ]
        try await syncer.sync(refs)

        let ids = try await db.queue.read { db in
            try Message.fetchAll(db).map(\.id).sorted()
        }
        XCTAssertEqual(ids, ["ok1", "ok2"])
        XCTAssertEqual(counts.values, [2])
    }

    // MARK: - Test 5: header extraction lands From/Subject in the right columns

    func testHeaderExtractionPopulatesColumns() async throws {
        let respBoundary = "rb5"
        StubURLProtocol.handler = { [self] req in
            if let t = self.tokenResponse(req) { return t }
            let parts: [(Int, String, [(String, String)], String)] = [
                (200, "OK", [("Content-Type", "application/json")],
                 self.gmailMessageJSON(
                    id: "m1", threadId: "t1", snippet: "s1",
                    labelIds: ["INBOX"], internalDate: "1700000000000",
                    headers: [
                        ("From", "alice@example.com"),
                        ("Subject", "Hello world"),
                        ("To", "bob@example.com, carol@example.com")
                    ]
                 ))
            ]
            let body = self.makeBatchResponseBody(boundary: respBoundary, parts: parts)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(respBoundary)"]
            )!
            return (resp, body)
        }

        let db = try makeDB()
        let syncer = MetadataBatchSyncer(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1"
        )
        try await syncer.sync([MessageRef(id: "m1", threadId: "t1")])

        let row = try await db.queue.read { try Message.fetchOne($0, key: "m1") }
        XCTAssertEqual(row?.fromAddr, "alice@example.com")
        XCTAssertEqual(row?.subject, "Hello world")
        XCTAssertEqual(row?.toAddrs, ["bob@example.com", "carol@example.com"])
    }
}
