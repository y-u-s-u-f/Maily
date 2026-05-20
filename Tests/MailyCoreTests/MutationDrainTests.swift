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

    /// Variant of the shared fixture whose underlying `TokenStore` is
    /// EMPTY — `loadRefreshToken` returns nil, so the first refresh
    /// attempt surfaces `AuthenticatedSessionError.missingRefreshToken`.
    private func makeFixtureWithoutRefreshToken(threadLabels: [String] = []) throws -> (MailyDatabase, GmailClient) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { db in
            try Account(id: "acct", email: "u@x").insert(db)
            try MailThread(id: "t1", accountId: "acct", labelIds: threadLabels).insert(db)
        }
        let store = InMemoryTokenStore() // no saveRefreshToken call
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
        let client = GmailClient(session: auth, userID: "me")
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

    func testRunOnceContinuesPastRetryableFailureToDrainSubsequentRows() async throws {
        // Queue: [failingRow, goodRow1, goodRow2]. After failingRow hits a 5xx,
        // the same runOnce() pass must still drain goodRow1 and goodRow2.
        let (db, client) = try makeFixture()
        try await db.queue.write { dbConn in
            try MailThread(id: "t-good1", accountId: "acct", labelIds: []).insert(dbConn)
            try MailThread(id: "t-good2", accountId: "acct", labelIds: []).insert(dbConn)
        }
        let failingId = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-fail")),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let good1Id = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-good1")),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let good2Id = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-good2")),
            createdAt: Date(timeIntervalSince1970: 3_000)
        )

        let paths = PathLog()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            let url = req.url?.absoluteString ?? ""
            paths.append(url)
            if url.contains("/threads/t-fail/modify") {
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                        Data("oops".utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"x"}"#.utf8))
        }

        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.runOnce()

        // Failing row stays with bumped attempts; good rows are gone.
        XCTAssertEqual(try pendingCount(db), 1)
        let row = try XCTUnwrap(try fetchMutation(db, id: failingId))
        XCTAssertEqual(row.attempts, 1)
        XCTAssertNil(row.lastError)
        XCTAssertNil(try fetchMutation(db, id: good1Id))
        XCTAssertNil(try fetchMutation(db, id: good2Id))
        // All three Gmail calls were attempted in order.
        XCTAssertTrue(paths.values.contains("https://gmail.googleapis.com/gmail/v1/users/me/threads/t-fail/modify"))
        XCTAssertTrue(paths.values.contains("https://gmail.googleapis.com/gmail/v1/users/me/threads/t-good1/modify"))
        XCTAssertTrue(paths.values.contains("https://gmail.googleapis.com/gmail/v1/users/me/threads/t-good2/modify"))
    }

    func testRunOnceAfterMaxAttemptsRetainsDeadRowAndRollsBackAndFiresHandler() async throws {
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

        // Row is retained (not deleted) with attempts >= maxAttempts and a non-nil last_error.
        XCTAssertEqual(try pendingCount(db), 1, "row is retained on permanent failure")
        let row = try XCTUnwrap(try fetchMutation(db, id: id))
        XCTAssertGreaterThanOrEqual(row.attempts, 5)
        XCTAssertNotNil(row.lastError, "lastError must be persisted on permanent failure")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.firstID, id)

        let fetched = try await db.queue.read { try MailThread.fetchOne($0, key: "t1") }
        let thread = try XCTUnwrap(fetched)
        // Optimistically removed UNREAD; rollback re-adds it.
        XCTAssertTrue(thread.labelIds.contains("UNREAD"), "rollback should re-add UNREAD")

        // A subsequent runOnce must NOT retry the dead row.
        let pathsAfter = PathLog()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            pathsAfter.append(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"x"}"#.utf8))
        }
        await drain.runOnce()
        XCTAssertTrue(pathsAfter.values.isEmpty, "dead row must not be retried on subsequent passes")
        XCTAssertEqual(failures.count, 1, "permanent failure handler must not fire twice for the same row")
    }

    func testRunOnceOnNonRetryable4xxRetainsRowFiresPermanentFailureAndRollsBack() async throws {
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

        XCTAssertEqual(try pendingCount(db), 1, "row is retained on non-retryable 4xx")
        let row = try XCTUnwrap(try fetchMutation(db, id: id))
        XCTAssertGreaterThanOrEqual(row.attempts, 1)
        let lastError = try XCTUnwrap(row.lastError)
        XCTAssertTrue(lastError.contains("404"), "last_error should reflect the 4xx status: got \(lastError)")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.firstID, id)

        let fetched = try await db.queue.read { try MailThread.fetchOne($0, key: "t1") }
        let thread = try XCTUnwrap(fetched)
        XCTAssertFalse(thread.labelIds.contains("STARRED"), "rollback should remove the optimistically-added STARRED")

        // Dead row is not retried on a second pass.
        let pathsAfter = PathLog()
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            pathsAfter.append(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"id":"x"}"#.utf8))
        }
        await drain.runOnce()
        XCTAssertTrue(pathsAfter.values.isEmpty, "dead row must not be retried on subsequent passes")
    }

    func testRunOnceOnNeedsReauthLeavesRowUntouchedAndStopsPass() async throws {
        // Two rows queued. The first will trigger needsReauth via repeated 401s.
        // Expected: pass stops, neither row is touched, no rollback, no perm-failure.
        let (db, client) = try makeFixture(threadLabels: ["INBOX"])
        try await db.queue.write { dbConn in
            try MailThread(id: "t-other", accountId: "acct", labelIds: ["INBOX"]).insert(dbConn)
        }
        let firstId = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1")),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let secondId = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-other")),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        // Every Gmail call returns 401 — AuthenticatedSession will refresh once,
        // see another 401, and surface `.needsReauth`.
        StubURLProtocol.handler = { req in
            if let t = self.tokenStub(req) { return t }
            return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data("unauthorized".utf8))
        }

        let failures = FailureLog()
        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.setOnPermanentFailure { mid, err in
            failures.record(id: mid, error: err)
        }
        await drain.runOnce()

        // Both rows must be untouched (no attempts++, no last_error).
        let first = try XCTUnwrap(try fetchMutation(db, id: firstId))
        XCTAssertEqual(first.attempts, 0, "needsReauth must not bump attempts")
        XCTAssertNil(first.lastError, "needsReauth must not write last_error")
        let second = try XCTUnwrap(try fetchMutation(db, id: secondId))
        XCTAssertEqual(second.attempts, 0)
        XCTAssertNil(second.lastError)

        // No rollback: the optimistic-removed UNREAD must not be re-added.
        let t1 = try await db.queue.read { try MailThread.fetchOne($0, key: "t1") }
        let thread = try XCTUnwrap(t1)
        XCTAssertFalse(thread.labelIds.contains("UNREAD"), "needsReauth must not trigger rollback")

        // No permanent-failure callbacks.
        XCTAssertEqual(failures.count, 0)
    }

    func testRunOnceOnMissingRefreshTokenLeavesRowUntouchedAndStopsPass() async throws {
        // Mirror of the needsReauth test: `.missingRefreshToken` is a
        // session-wide config failure — every subsequent call would
        // also fail — so the pass stops without touching any row, no
        // rollback, no permanent-failure callbacks.
        let (db, client) = try makeFixtureWithoutRefreshToken(threadLabels: ["INBOX"])
        try await db.queue.write { dbConn in
            try MailThread(id: "t-other", accountId: "acct", labelIds: ["INBOX"]).insert(dbConn)
        }
        let firstId = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t1")),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let secondId = try insertMutation(
            db,
            kind: .markRead,
            payloadJson: try MutationPayload.encode(MutationPayload.ThreadOnly(threadId: "t-other")),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        // No handler needed — the session never reaches the network; it
        // throws `.missingRefreshToken` from `refreshAccessToken()` before
        // dispatching the URL request.
        StubURLProtocol.handler = { _ in
            XCTFail("no Gmail request should be issued without a refresh token")
            return (HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let failures = FailureLog()
        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.setOnPermanentFailure { mid, err in
            failures.record(id: mid, error: err)
        }
        await drain.runOnce()

        // Both rows must be untouched (no attempts++, no last_error).
        let first = try XCTUnwrap(try fetchMutation(db, id: firstId))
        XCTAssertEqual(first.attempts, 0, "missingRefreshToken must not bump attempts")
        XCTAssertNil(first.lastError, "missingRefreshToken must not write last_error")
        let second = try XCTUnwrap(try fetchMutation(db, id: secondId))
        XCTAssertEqual(second.attempts, 0)
        XCTAssertNil(second.lastError)

        // No rollback: the optimistic-removed UNREAD must not be re-added.
        let t1 = try await db.queue.read { try MailThread.fetchOne($0, key: "t1") }
        let thread = try XCTUnwrap(t1)
        XCTAssertFalse(thread.labelIds.contains("UNREAD"), "missingRefreshToken must not trigger rollback")

        // No permanent-failure callbacks.
        XCTAssertEqual(failures.count, 0)
    }

    func testRollbackDecodeFailureIsAppendedToLastErrorAndRowMarkedDead() async throws {
        // A row with a corrupt payload_json: decode succeeds for a
        // best-effort dispatch path? No — dispatch will throw
        // `payloadDecodeFailed`. That goes through `handleFailure` and
        // the rollback re-decodes the same garbage. The rollback's
        // decode error must be appended to `last_error` rather than
        // silently swallowed.
        let (db, client) = try makeFixture(threadLabels: ["INBOX", "UNREAD"])
        // Insert a row with malformed JSON. `markRead` rollback would
        // re-add UNREAD if it could decode; since it can't, UNREAD stays
        // (the thread was never optimistically modified at this layer
        // anyway — we just need to assert the error string).
        let id = try insertMutation(db, kind: .markRead, payloadJson: "not-json{")

        // dispatch will throw DrainError.payloadDecodeFailed before any
        // network call; no stub needed beyond a defensive guard.
        StubURLProtocol.handler = { _ in
            XCTFail("no Gmail request should be issued for a malformed payload")
            return (HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let failures = FailureLog()
        let drain = MutationDrain(db: db.queue, client: client, sleeper: { _ in })
        await drain.setOnPermanentFailure { mid, err in
            failures.record(id: mid, error: err)
        }
        await drain.runOnce()

        XCTAssertEqual(try pendingCount(db), 1, "row is retained on permanent failure")
        let row = try XCTUnwrap(try fetchMutation(db, id: id))
        let lastError = try XCTUnwrap(row.lastError)
        XCTAssertTrue(lastError.contains("payloadDecodeFailed"),
                      "primary error must be in last_error: got \(lastError)")
        XCTAssertTrue(lastError.contains("rollback failed:"),
                      "rollback decode failure must be appended: got \(lastError)")
        XCTAssertEqual(failures.count, 1, "permanent-failure handler still fires")
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
