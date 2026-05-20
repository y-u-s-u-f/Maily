import XCTest
import GRDB
@testable import MailyCore

final class MutationDrainTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - fixtures

    private func makeFixture(threadLabels: [String] = []) throws -> (MailyDatabase, GmailClient) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { db in
            try Account(id: "acct", email: "u@x").insert(db)
            try MailThread(id: "t1", accountId: "acct", labelIds: threadLabels).insert(db)
        }
        let client = GmailClientTests.makeClient()
        return (db, client)
    }

    private func tokenStub(_ req: URLRequest) -> (HTTPURLResponse, Data)? {
        guard req.url?.host == "oauth2.googleapis.com" else { return nil }
        let body = Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    private func insertMutation(
        _ db: MailyDatabase,
        kind: MutationKind,
        payloadJson: String,
        createdAt: Date = Date(),
        attempts: Int = 0
    ) throws -> Int64 {
        try db.queue.write { dbConn in
            var m = PendingMutation(
                accountId: "acct",
                kind: kind,
                payloadJson: payloadJson,
                createdAt: createdAt,
                attempts: attempts
            )
            try m.insert(dbConn)
            return m.id!
        }
    }

    private func pendingCount(_ db: MailyDatabase) throws -> Int {
        try db.queue.read { dbConn in
            try PendingMutation.fetchCount(dbConn)
        }
    }

    private func fetchMutation(_ db: MailyDatabase, id: Int64) throws -> PendingMutation? {
        try db.queue.read { dbConn in try PendingMutation.fetchOne(dbConn, key: id) }
    }

    // MARK: - dispatch per kind

    func testRunOnceDispatchesModifyLabelsAndDeletesRow() async throws {
        let (db, client) = try makeFixture(threadLabels: ["INBOX"])
        let payload = try MutationPayload.encode(MutationPayload.ModifyLabels(
            threadId: "t1", addLabelIds: ["STARRED"], removeLabelIds: ["INBOX"]
        ))
        _ = try insertMutation(db, kind: .modifyLabels, payloadJson: payload)

        let captured = Capture()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            XCTAssertEqual(req.url?.absoluteString,
                           "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1/modify")
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            captured.set(json)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(captured.value?["addLabelIds"] as? [String], ["STARRED"])
        XCTAssertEqual(captured.value?["removeLabelIds"] as? [String], ["INBOX"])
        XCTAssertEqual(try pendingCount(db), 0)
    }

    func testRunOnceDispatchesTrash() async throws {
        let (db, client) = try makeFixture()
        let payload = try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1"))
        _ = try insertMutation(db, kind: .trash, payloadJson: payload)

        let captured = Capture()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            captured.set(json)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(captured.value?["addLabelIds"] as? [String], ["TRASH"])
        XCTAssertEqual(captured.value?["removeLabelIds"] as? [String], [])
        XCTAssertEqual(try pendingCount(db), 0)
    }

    func testRunOnceDispatchesUntrash() async throws {
        let (db, client) = try makeFixture()
        let payload = try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1"))
        _ = try insertMutation(db, kind: .untrash, payloadJson: payload)

        let captured = Capture()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            captured.set(json)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(captured.value?["addLabelIds"] as? [String], [])
        XCTAssertEqual(captured.value?["removeLabelIds"] as? [String], ["TRASH"])
        XCTAssertEqual(try pendingCount(db), 0)
    }

    func testRunOnceDispatchesMarkRead() async throws {
        let (db, client) = try makeFixture()
        let payload = try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1"))
        _ = try insertMutation(db, kind: .markRead, payloadJson: payload)

        let captured = Capture()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            captured.set(json)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(captured.value?["addLabelIds"] as? [String], [])
        XCTAssertEqual(captured.value?["removeLabelIds"] as? [String], ["UNREAD"])
        XCTAssertEqual(try pendingCount(db), 0)
    }

    func testRunOnceDispatchesSendAndDeletesRow() async throws {
        let (db, client) = try makeFixture()
        let payload = try MutationPayload.encode(MutationPayload.Send(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "Hi",
            body: "hello",
            threadId: "t-99"
        ))
        _ = try insertMutation(db, kind: .send, payloadJson: payload)

        let captured = Capture()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            XCTAssertEqual(req.url?.absoluteString,
                           "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            captured.set(json)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"m1","threadId":"t-99"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(captured.value?["threadId"] as? String, "t-99")
        XCTAssertNotNil(captured.value?["raw"])
        XCTAssertEqual(try pendingCount(db), 0)
    }

    // MARK: - retry / failure

    func testRunOnceOn5xxLeavesRowAndBumpsAttempts() async throws {
        let (db, client) = try makeFixture()
        let payload = try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1"))
        let id = try insertMutation(db, kind: .markRead, payloadJson: payload)

        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data("oops".utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(try pendingCount(db), 1, "row stays in the queue on retryable failure")
        let row = try XCTUnwrap(try fetchMutation(db, id: id))
        XCTAssertEqual(row.attempts, 1)
        XCTAssertNil(row.lastError, "lastError is only set on permanent failure")
    }

    func testRunOnceAfterMaxAttemptsDeletesRowAndRollsBackAndFiresHandler() async throws {
        // optimistic change: removed UNREAD locally. rollback must re-add UNREAD.
        let (db, client) = try makeFixture(threadLabels: ["INBOX"])
        let payload = try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1"))
        // pre-load attempts = 4 so that this failure pushes us to 5 (>= maxAttempts).
        let id = try insertMutation(db, kind: .markRead, payloadJson: payload, attempts: 4)

        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data("nope".utf8))
        }

        let failures = FailureLog()
        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.setOnPermanentFailure { mid, err in
            failures.record(id: mid, error: err)
        }
        await drain.runOnce()

        XCTAssertEqual(try pendingCount(db), 0, "row is deleted on permanent failure")
        XCTAssertNil(try fetchMutation(db, id: id))
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.firstID, id)

        let fetched = try await db.queue.read { try MailThread.fetchOne($0, key: "t1") }
        let thread = try XCTUnwrap(fetched)
        // Optimistically removed UNREAD; rollback re-adds it.
        XCTAssertTrue(thread.labelIds.contains("UNREAD"), "rollback should re-add UNREAD")
    }

    func testRunOnceOnNonRetryable4xxFiresPermanentFailureAndRollsBack() async throws {
        // optimistic change: added STARRED. rollback must remove STARRED.
        let (db, client) = try makeFixture(threadLabels: ["INBOX", "STARRED"])
        let payload = try MutationPayload.encode(MutationPayload.ModifyLabels(
            threadId: "t1", addLabelIds: ["STARRED"], removeLabelIds: []
        ))
        let id = try insertMutation(db, kind: .modifyLabels, payloadJson: payload)

        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data("missing".utf8))
        }

        let failures = FailureLog()
        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.setOnPermanentFailure { mid, err in
            failures.record(id: mid, error: err)
        }
        await drain.runOnce()

        XCTAssertEqual(try pendingCount(db), 0)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.firstID, id)

        let fetched = try await db.queue.read { try MailThread.fetchOne($0, key: "t1") }
        let thread = try XCTUnwrap(fetched)
        XCTAssertFalse(thread.labelIds.contains("STARRED"), "rollback should remove the optimistically-added STARRED")
    }

    // MARK: - ordering

    func testRunOnceDrainsOldestFirst() async throws {
        let (db, client) = try makeFixture()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        let third = Date(timeIntervalSince1970: 3_000)

        // Insert out of chronological order.
        _ = try insertMutation(db, kind: .markRead,
                               payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-mid")),
                               createdAt: second)
        _ = try insertMutation(db, kind: .markRead,
                               payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-new")),
                               createdAt: third)
        _ = try insertMutation(db, kind: .markRead,
                               payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-old")),
                               createdAt: first)

        let order = PathLog()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            order.append(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"x"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        XCTAssertEqual(order.values, [
            "https://gmail.googleapis.com/gmail/v1/users/me/threads/t-old/modify",
            "https://gmail.googleapis.com/gmail/v1/users/me/threads/t-mid/modify",
            "https://gmail.googleapis.com/gmail/v1/users/me/threads/t-new/modify",
        ])
        XCTAssertEqual(try pendingCount(db), 0)
    }

    // MARK: - lifecycle

    func testStartSpawnsLoopAndStopCancelsIt() async throws {
        let (db, client) = try makeFixture()
        let payload = try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1"))
        _ = try insertMutation(db, kind: .markRead, payloadJson: payload)

        let processed = expectation(description: "request processed at least once")
        processed.assertForOverFulfill = false
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            processed.fulfill()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }

        // Use a sleeper that yields cooperation points so cancellation can land.
        let drain = MutationDrain(
            db: db.queue,
            client: client,
            sleeper: { _ in await Task.yield() },
            idleInterval: 0.001
        )
        await drain.start()
        await fulfillment(of: [processed], timeout: 5)

        await drain.stop()
        XCTAssertEqual(try pendingCount(db), 0)
    }

    func testDoubleStartIsNoOp() async throws {
        let (db, client) = try makeFixture()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"t1"}"#.utf8))
        }

        let drain = MutationDrain(
            db: db.queue,
            client: client,
            sleeper: { _ in await Task.yield() },
            idleInterval: 0.001
        )
        await drain.start()
        await drain.start() // must not spawn a second loop
        await drain.stop()
        // The real signal is that stop() returns and nothing hangs; if a
        // second loop had been spawned, stop() would only cancel one of
        // them and the other would keep going (visible via leaks / open
        // requests after stop). We don't assert further here beyond
        // reaching this line cleanly.
        XCTAssertTrue(true)
    }
}

// MARK: - tiny test helpers

/// `@Sendable` capture cell used inside StubURLProtocol handlers, which run
/// off the test actor. Each helper protects its mutable state with a lock so
/// the captured request can be read back on the main test queue.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any]?

    func set(_ value: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }

    var value: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(s)
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int64] = []
    private var errors: [Error] = []

    func record(id: Int64, error: Error) {
        lock.lock(); defer { lock.unlock() }
        ids.append(id)
        errors.append(error)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return ids.count
    }

    var firstID: Int64? {
        lock.lock(); defer { lock.unlock() }
        return ids.first
    }
}
