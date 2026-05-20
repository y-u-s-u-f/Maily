import XCTest
import GRDB
@testable import MailyCore

final class HistoryWatcherTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - fixture

    private func makeFixture(baseline: String? = "h-1") throws -> (MailyDatabase, AccountRepository) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write {
            try Account(id: "acct", email: "u@x", historyId: baseline).insert($0)
        }
        return (db, AccountRepository(queue: db.queue))
    }

    private static func oauthOK(_ req: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
    }

    // MARK: - test 1: empty response, history_id refreshed, no row writes

    func testEmptyHistoryResponseUpdatesHistoryIdWithoutWritingRows() async throws {
        let (db, repo) = try makeFixture(baseline: "h-1")
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"historyId":"h-1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()

        let polledBox = CountBox()
        let watcher = HistoryWatcher(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            onPolled: { n in Task { await polledBox.add(n) } }
        )
        try await watcher.pollOnce()

        let messageCount = try await db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages") } ?? -1
        let threadCount = try await db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM threads") } ?? -1
        XCTAssertEqual(messageCount, 0)
        XCTAssertEqual(threadCount, 0)
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "h-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        let polled = await polledBox.value
        XCTAssertEqual(polled, 0)
    }

    // MARK: - test 2: messagesAdded

    func testMessagesAddedUpsertsMessageAndThread() async throws {
        let (db, repo) = try makeFixture()
        let payload = """
        {
          "history": [
            {
              "id": "10",
              "messagesAdded": [
                {"message": {"id": "m-1", "threadId": "t-1"}, "labelIds": ["INBOX", "UNREAD"]}
              ]
            }
          ],
          "historyId": "h-2"
        }
        """
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8))
        }
        let client = GmailClientTests.makeClient()
        let watcher = HistoryWatcher(
            client: client, db: db.queue, accountRepo: repo, accountID: "acct"
        )
        try await watcher.pollOnce()

        let msg = try await db.queue.read { try Message.fetchOne($0, key: "m-1") }
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.threadId, "t-1")
        XCTAssertEqual(msg?.accountId, "acct")
        XCTAssertEqual(Set(msg?.labelIds ?? []), Set(["INBOX", "UNREAD"]))
        let thread = try await db.queue.read { try MailThread.fetchOne($0, key: "t-1") }
        XCTAssertNotNil(thread)
        XCTAssertEqual(thread?.accountId, "acct")
        XCTAssertEqual(Set(thread?.labelIds ?? []), Set(["INBOX", "UNREAD"]))
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "h-2")
    }

    // MARK: - test 3: messagesDeleted recomputes counts

    func testMessagesDeletedRemovesMessageAndRecomputesCounts() async throws {
        let (db, repo) = try makeFixture()
        try await db.queue.write { d in
            try MailThread(id: "t-1", accountId: "acct", unreadCount: 1, messageCount: 1, labelIds: ["INBOX"]).insert(d)
            try Message(id: "m-1", threadId: "t-1", accountId: "acct", labelIds: ["INBOX", "UNREAD"]).insert(d)
        }
        let payload = """
        {
          "history": [
            {"id": "11", "messagesDeleted": [{"message": {"id": "m-1", "threadId": "t-1"}}]}
          ],
          "historyId": "h-3"
        }
        """
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8))
        }
        let client = GmailClientTests.makeClient()
        let watcher = HistoryWatcher(
            client: client, db: db.queue, accountRepo: repo, accountID: "acct"
        )
        try await watcher.pollOnce()

        let stillThere = try await db.queue.read { try Message.fetchOne($0, key: "m-1") }
        XCTAssertNil(stillThere)
        let thread = try await db.queue.read { try MailThread.fetchOne($0, key: "t-1") }
        XCTAssertEqual(thread?.messageCount, 0)
        XCTAssertEqual(thread?.unreadCount, 0)
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "h-3")
    }

    // MARK: - test 4: labelsAdded UNREAD increments thread.unreadCount

    func testLabelsAddedUnreadIncrementsThreadUnreadCount() async throws {
        let (db, repo) = try makeFixture()
        try await db.queue.write { d in
            try MailThread(id: "t-1", accountId: "acct", unreadCount: 0, messageCount: 1, labelIds: ["INBOX"]).insert(d)
            try Message(id: "m-1", threadId: "t-1", accountId: "acct", labelIds: ["INBOX"]).insert(d)
        }
        let payload = """
        {
          "history": [
            {"id": "12", "labelsAdded": [{"message": {"id": "m-1", "threadId": "t-1"}, "labelIds": ["UNREAD"]}]}
          ],
          "historyId": "h-4"
        }
        """
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(payload.utf8))
        }
        let client = GmailClientTests.makeClient()
        let watcher = HistoryWatcher(
            client: client, db: db.queue, accountRepo: repo, accountID: "acct"
        )
        try await watcher.pollOnce()

        let msg = try await db.queue.read { try Message.fetchOne($0, key: "m-1") }
        XCTAssertTrue(msg?.labelIds.contains("UNREAD") ?? false)
        XCTAssertTrue(msg?.labelIds.contains("INBOX") ?? false)
        let thread = try await db.queue.read { try MailThread.fetchOne($0, key: "t-1") }
        XCTAssertEqual(thread?.unreadCount, 1)
    }

    // MARK: - test 5: 404 history-expired callback

    func testHistoryIdExpired404TriggersCallback() async throws {
        let (db, repo) = try makeFixture(baseline: "expired")
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8))
        }
        let client = GmailClientTests.makeClient()
        let flagBox = FlagBox()
        let watcher = HistoryWatcher(
            client: client, db: db.queue, accountRepo: repo, accountID: "acct",
            onHistoryExpired: { Task { await flagBox.set() } }
        )
        try await watcher.pollOnce()

        try await Task.sleep(nanoseconds: 50_000_000)
        let flag = await flagBox.value
        XCTAssertTrue(flag)
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "expired")
    }

    // MARK: - test 7: updateState wakes the current sleep (fix #1)
    //
    // After the first poll the watcher is sleeping for 15s in `.focused`.
    // We flip to `.background`, which should cancel that sleep and cause
    // the loop to immediately re-evaluate cadence — the NEXT recorded
    // sleep should be 300s, not 15s.
    func testUpdateStateWakesCurrentSleepAndAppliesNewCadence() async throws {
        let (db, repo) = try makeFixture()
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"historyId":"h-1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()

        let recorder = WakeableSleeperRecorder()
        let watcher = HistoryWatcher(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            sleeper: { interval in await recorder.sleep(interval) }
        )
        await watcher.start()

        // Wait for the first sleep to be entered (15s, post-poll).
        try await recorder.waitForRecorded(count: 1, timeoutNS: 2_000_000_000)
        let first = await recorder.intervals
        XCTAssertEqual(first.first, 15)

        // Flip state — watcher must cancel the 15s sleep so the loop wakes
        // and records a fresh 300s sleep without us calling release().
        await watcher.updateState(.background)

        try await recorder.waitForRecorded(count: 2, timeoutNS: 2_000_000_000)
        let second = await recorder.intervals
        XCTAssertEqual(second.count >= 2 ? second[1] : nil, 300)

        await recorder.releaseAll()
        await watcher.stop()
    }

    // MARK: - test 8: concurrent pollOnce coalesces (fix #3)

    func testConcurrentPollOnceCoalescesIntoSingleNetworkRoundTrip() async throws {
        let (db, repo) = try makeFixture()
        let hits = HitCounter()
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            // Synchronous bump — protocol invokes this on a serial queue.
            Task { await hits.bump() }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"historyId":"h-1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()
        let watcher = HistoryWatcher(
            client: client, db: db.queue, accountRepo: repo, accountID: "acct"
        )

        async let a: Void = watcher.pollOnce()
        async let b: Void = watcher.pollOnce()
        _ = try await (a, b)

        // Allow the Task that bumps the counter to flush.
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await hits.value
        XCTAssertEqual(count, 1, "expected one history.list round-trip, got \(count)")
    }

    // MARK: - test 6: cadence reacts to updateState

    func testUpdateStateBackgroundChangesCadence() async throws {
        let (db, repo) = try makeFixture()
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return Self.oauthOK(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"historyId":"h-1"}"#.utf8))
        }
        let client = GmailClientTests.makeClient()

        let recorder = SleeperRecorder()
        let watcher = HistoryWatcher(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            sleeper: { interval in await recorder.recordAndWait(interval) }
        )
        await watcher.start()

        // wait until first sleep is recorded (post-poll)
        try await recorder.waitForRecorded(count: 1, timeoutNS: 2_000_000_000)
        let first = await recorder.intervals
        XCTAssertEqual(first.first, 15)

        await watcher.updateState(.background)
        await recorder.release()  // let it proceed past the first sleep

        try await recorder.waitForRecorded(count: 2, timeoutNS: 2_000_000_000)
        let second = await recorder.intervals
        XCTAssertEqual(second.count >= 2 ? second[1] : nil, 300)

        await recorder.release()  // unblock the second sleep so the loop can exit
        await watcher.stop()
    }
}

// MARK: - helpers

actor CountBox {
    var value: Int = 0
    func add(_ n: Int) { value += n }
}

actor FlagBox {
    var value: Bool = false
    func set() { value = true }
}

/// Records each interval the sleeper is called with, and blocks each call on
/// a per-call continuation so the test can advance loop iterations one at a
/// time. Call `release()` once per recorded sleep to let the watcher proceed.
actor SleeperRecorder {
    private(set) var intervals: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReleases: Int = 0
    private var recordedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func recordAndWait(_ interval: TimeInterval) async {
        intervals.append(interval)
        // notify anyone waiting for a recorded-count threshold
        let count = intervals.count
        recordedWaiters.removeAll { (target, cont) in
            if count >= target { cont.resume(); return true }
            return false
        }

        if pendingReleases > 0 {
            pendingReleases -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            pendingReleases += 1
        }
    }

    func waitForRecorded(count target: Int, timeoutNS: UInt64) async throws {
        if intervals.count >= target { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task { await self.appendRecordedWaiter(target: target, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNS)
                throw TimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func appendRecordedWaiter(target: Int, cont: CheckedContinuation<Void, Never>) {
        if intervals.count >= target { cont.resume() } else { recordedWaiters.append((target, cont)) }
    }
}

struct TimeoutError: Error {}

actor HitCounter {
    var value: Int = 0
    func bump() { value += 1 }
}

/// Sleeper that records each interval and blocks on `Task.sleep` (which is
/// cancellation-aware). Used to verify that `updateState` cancels an in-flight
/// sleep — when the watcher cancels its `sleepTask`, `Task.sleep` throws and
/// this returns early, letting the run loop reach the next iteration.
actor WakeableSleeperRecorder {
    private(set) var intervals: [TimeInterval] = []
    private var recordedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var liveSleeps: [Task<Void, Never>] = []

    nonisolated func sleep(_ interval: TimeInterval) async {
        await record(interval)
        // Use a long sleep so the test's cancellation path is the only way
        // out. 60s is far above the 2s test timeouts.
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
    }

    private func record(_ interval: TimeInterval) {
        intervals.append(interval)
        let count = intervals.count
        recordedWaiters.removeAll { (target, cont) in
            if count >= target { cont.resume(); return true }
            return false
        }
    }

    func releaseAll() {
        // No-op: the watcher cancels sleepTask in stop(), which makes the
        // wrapping Task cancel our `Task.sleep` above. Nothing needed here.
    }

    func waitForRecorded(count target: Int, timeoutNS: UInt64) async throws {
        if intervals.count >= target { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task { await self.appendRecordedWaiter(target: target, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNS)
                throw TimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func appendRecordedWaiter(target: Int, cont: CheckedContinuation<Void, Never>) {
        if intervals.count >= target { cont.resume() } else { recordedWaiters.append((target, cont)) }
    }
}
