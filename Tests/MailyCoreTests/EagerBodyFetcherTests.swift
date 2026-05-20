import XCTest
import GRDB
@testable import MailyCore

// Thread-safe accumulator usable in @Sendable test closures.
private final class IntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func append(_ value: Int) { lock.withLock { _values.append(value) } }
}

final class EagerBodyFetcherTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// base64url-encode a UTF-8 string (URL-safe, no padding) — matches what
    /// the Gmail API returns in `payload.body.data`.
    private static func base64URL(_ s: String) -> String {
        let data = Data(s.utf8)
        var b = data.base64EncodedString()
        b = b.replacingOccurrences(of: "+", with: "-")
        b = b.replacingOccurrences(of: "/", with: "_")
        b = b.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return b
    }

    /// Extract message ids from a batch request body by scanning for
    /// `GET /gmail/v1/users/me/messages/<id>` lines.
    private static func extractMessageIDs(fromBatchRequestBody body: Data) -> [String] {
        let getPrefix = "GET /gmail/v1/users/me/messages/"
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        var ids: [String] = []
        for line in bodyStr.components(separatedBy: "\r\n") where line.hasPrefix(getPrefix) {
            let rest = line.dropFirst(getPrefix.count)
            if let qIdx = rest.firstIndex(of: "?") {
                ids.append(String(rest[..<qIdx]))
            } else {
                ids.append(String(rest))
            }
        }
        return ids
    }

    /// JSON for one GmailMessage with a payload that has a single text/plain
    /// body (mimic Gmail's `format=full` response for a simple message).
    fileprivate static func plainTextMessageJSON(id: String, threadId: String, plainText: String) -> String {
        let obj: [String: Any] = [
            "id": id,
            "threadId": threadId,
            "payload": [
                "mimeType": "text/plain",
                "body": ["data": base64URL(plainText), "size": plainText.utf8.count]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// JSON for one GmailMessage whose payload is a multipart with one
    /// text/html part only (no text/plain).
    fileprivate static func htmlOnlyMessageJSON(id: String, threadId: String, html: String) -> String {
        let obj: [String: Any] = [
            "id": id,
            "threadId": threadId,
            "payload": [
                "mimeType": "multipart/alternative",
                "parts": [
                    [
                        "mimeType": "text/html",
                        "body": ["data": base64URL(html), "size": html.utf8.count]
                    ]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func makeDB() throws -> MailyDatabase {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct-1", email: "u@x").insert($0) }
        return db
    }

    /// Insert a thread + message row with no body. Optionally pre-set
    /// `bodyFetchedAt` so tests can verify "skip already-fetched" behavior.
    private func insertMessage(
        in db: MailyDatabase,
        id: String,
        threadId: String,
        accountId: String = "acct-1",
        date: Date,
        labelIds: [String] = ["INBOX"],
        bodyFetchedAt: Date? = nil
    ) throws {
        try db.queue.write { dbConn in
            let thread = MailThread(id: threadId, accountId: accountId)
            try thread.insert(dbConn, onConflict: .ignore)
            let msg = Message(
                id: id,
                threadId: threadId,
                accountId: accountId,
                date: date,
                bodyFetchedAt: bodyFetchedAt,
                labelIds: labelIds
            )
            try msg.upsert(dbConn)
        }
    }

    fileprivate static func installBatchHandler(
        boundary: String,
        jsonFor: @escaping @Sendable (String) -> (status: Int, json: String)
    ) {
        StubURLProtocol.handler = { req in
            if let t = tokenStubResponse(for: req) { return t }
            let ids = extractMessageIDs(fromBatchRequestBody: req.httpBody ?? Data())
            let parts: [(Int, String, [(String, String)], String)] = ids.map { id in
                let r = jsonFor(id)
                let reason = r.status == 200 ? "OK" : (r.status == 404 ? "Not Found" : "Error")
                return (r.status, reason, [("Content-Type", "application/json")], r.json)
            }
            let body = makeBatchResponseBody(boundary: boundary, parts: parts)
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "multipart/mixed; boundary=\(boundary)"]
            )!
            return (resp, body)
        }
    }

    // MARK: - Test 1: Empty inbox → no HTTP call

    func testNoEligibleRowsIssuesNoBatchCall() async throws {
        StubURLProtocol.handler = { req in
            if let t = tokenStubResponse(for: req) { return t }
            XCTFail("Should not have made any non-token request")
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        let db = try makeDB()
        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1"
        )
        try await fetcher.fetchTopInbox()

        let batchRequests = StubURLProtocol.capturedRequests.filter {
            $0.url?.absoluteString.contains("/batch/gmail/v1") == true
        }
        XCTAssertEqual(batchRequests.count, 0)
    }

    // MARK: - Test 2: < limit eligible messages → one batch call, all updated

    func testSmallInboxFetchesAllInOneBatch() async throws {
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            try insertMessage(in: db, id: "m\(i)", threadId: "t\(i)",
                              date: base.addingTimeInterval(TimeInterval(i)))
        }

        Self.installBatchHandler(boundary: "rbA") { id in
            (200, Self.plainTextMessageJSON(id: id, threadId: "t-\(id)", plainText: "body-\(id)"))
        }

        let progress = IntCounter()
        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1",
            onProgress: { progress.append($0) }
        )
        try await fetcher.fetchTopInbox()

        let batchRequests = StubURLProtocol.capturedRequests.filter {
            $0.url?.absoluteString.contains("/batch/gmail/v1") == true
        }
        XCTAssertEqual(batchRequests.count, 1)

        let rows = try await db.queue.read { try Message.fetchAll($0) }
        XCTAssertEqual(rows.count, 5)
        for r in rows {
            XCTAssertNotNil(r.bodyFetchedAt, "row \(r.id) should have bodyFetchedAt set")
            XCTAssertEqual(r.bodyText, "body-\(r.id)")
        }
        XCTAssertEqual(progress.values, [5])
    }

    // MARK: - Test 3: > limit messages → only limit fetched

    func testRespectsLimitAcrossMessages() async throws {
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<7 {
            try insertMessage(in: db, id: "m\(i)", threadId: "t\(i)",
                              date: base.addingTimeInterval(TimeInterval(i)))
        }

        Self.installBatchHandler(boundary: "rbB") { id in
            (200, Self.plainTextMessageJSON(id: id, threadId: "t-\(id)", plainText: "b-\(id)"))
        }

        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1",
            limit: 4,
            chunkSize: 2
        )
        try await fetcher.fetchTopInbox()

        // Total subrequests across all batch calls should equal limit (4).
        let batchRequests = StubURLProtocol.capturedRequests.filter {
            $0.url?.absoluteString.contains("/batch/gmail/v1") == true
        }
        let totalSubrequests = batchRequests.reduce(0) { sum, req in
            sum + Self.extractMessageIDs(fromBatchRequestBody: req.httpBody ?? Data()).count
        }
        XCTAssertEqual(totalSubrequests, 4)

        // The 4 newest message ids (m3..m6) should be the ones fetched.
        let fetched = try await db.queue.read { db in
            try Message.fetchAll(db).filter { $0.bodyFetchedAt != nil }.map(\.id).sorted()
        }
        XCTAssertEqual(fetched, ["m3", "m4", "m5", "m6"])
    }

    // MARK: - Test 4: Messages with body_fetched_at NOT NULL are skipped

    func testSkipsAlreadyFetchedMessages() async throws {
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // m0, m1 already fetched; m2, m3 not yet fetched.
        let alreadyFetched = Date(timeIntervalSince1970: 1_600_000_000)
        try insertMessage(in: db, id: "m0", threadId: "t0",
                          date: base.addingTimeInterval(0), bodyFetchedAt: alreadyFetched)
        try insertMessage(in: db, id: "m1", threadId: "t1",
                          date: base.addingTimeInterval(1), bodyFetchedAt: alreadyFetched)
        try insertMessage(in: db, id: "m2", threadId: "t2",
                          date: base.addingTimeInterval(2))
        try insertMessage(in: db, id: "m3", threadId: "t3",
                          date: base.addingTimeInterval(3))

        Self.installBatchHandler(boundary: "rbC") { id in
            (200, Self.plainTextMessageJSON(id: id, threadId: "t-\(id)", plainText: "x-\(id)"))
        }

        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1"
        )
        try await fetcher.fetchTopInbox()

        // Subrequests should only be issued for m2, m3.
        let batchRequests = StubURLProtocol.capturedRequests.filter {
            $0.url?.absoluteString.contains("/batch/gmail/v1") == true
        }
        XCTAssertEqual(batchRequests.count, 1)
        let issuedIDs = Self.extractMessageIDs(fromBatchRequestBody: batchRequests[0].httpBody ?? Data()).sorted()
        XCTAssertEqual(issuedIDs, ["m2", "m3"])
    }

    // MARK: - Test 5: text/plain body decoded from base64url

    func testDecodesTextPlainBase64URLCorrectly() async throws {
        let db = try makeDB()
        // Use a string that produces "+/=" in standard base64 to force the
        // URL-safe substitutions to matter.
        let original = "Hello, world!\nThis is a test — fancy chars: ☃ ✓ ~?>"
        try insertMessage(in: db, id: "m1", threadId: "t1",
                          date: Date(timeIntervalSince1970: 1_700_000_000))

        Self.installBatchHandler(boundary: "rbD") { id in
            (200, Self.plainTextMessageJSON(id: id, threadId: "t1", plainText: original))
        }

        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1"
        )
        try await fetcher.fetchTopInbox()

        let row = try await db.queue.read { try Message.fetchOne($0, key: "m1") }
        XCTAssertEqual(row?.bodyText, original)
        XCTAssertNil(row?.bodyHtml)
    }

    // MARK: - Test 6: HTML-only body → bodyHtml set, bodyText stripped

    func testHTMLOnlyBodyStoresHtmlAndStripsToText() async throws {
        let db = try makeDB()
        let html = "<p>Hello <b>world</b></p><br><div>line two</div>"
        try insertMessage(in: db, id: "m1", threadId: "t1",
                          date: Date(timeIntervalSince1970: 1_700_000_000))

        Self.installBatchHandler(boundary: "rbE") { id in
            (200, Self.htmlOnlyMessageJSON(id: id, threadId: "t1", html: html))
        }

        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1"
        )
        try await fetcher.fetchTopInbox()

        let row = try await db.queue.read { try Message.fetchOne($0, key: "m1") }
        XCTAssertEqual(row?.bodyHtml, html)
        XCTAssertNotNil(row?.bodyText)
        let text = row?.bodyText ?? ""
        // Must contain the visible words, no angle brackets.
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertTrue(text.contains("line two"))
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains(">"))
    }

    // MARK: - Test 7: Per-row 404 in a chunk → neighbors still updated

    func testPerRow404DoesNotAbortChunk() async throws {
        let db = try makeDB()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try insertMessage(in: db, id: "ok1", threadId: "tk1", date: base.addingTimeInterval(0))
        try insertMessage(in: db, id: "gone", threadId: "tg", date: base.addingTimeInterval(1))
        try insertMessage(in: db, id: "ok2", threadId: "tk2", date: base.addingTimeInterval(2))

        Self.installBatchHandler(boundary: "rbF") { id in
            if id == "gone" {
                return (404, #"{"error":"missing"}"#)
            }
            return (200, Self.plainTextMessageJSON(id: id, threadId: "t-\(id)", plainText: "p-\(id)"))
        }

        let progress = IntCounter()
        let fetcher = EagerBodyFetcher(
            client: MessagesListTests.makeClient(),
            db: db.queue,
            accountID: "acct-1",
            onProgress: { progress.append($0) }
        )
        try await fetcher.fetchTopInbox()

        let fetched = try await db.queue.read { db -> [(String, String?, Date?)] in
            try Message.fetchAll(db).map { ($0.id, $0.bodyText, $0.bodyFetchedAt) }
        }
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.0, $0) })
        XCTAssertEqual(byID["ok1"]?.1, "p-ok1")
        XCTAssertNotNil(byID["ok1"]?.2)
        XCTAssertEqual(byID["ok2"]?.1, "p-ok2")
        XCTAssertNotNil(byID["ok2"]?.2)
        XCTAssertNil(byID["gone"]?.1)
        XCTAssertNil(byID["gone"]?.2)

        XCTAssertEqual(progress.values, [2])
    }
}
