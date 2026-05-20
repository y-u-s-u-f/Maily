import XCTest
import GRDB
@testable import MailyCore
@testable import MailyUI

private actor PosterCallLog {
    struct Call: Equatable, Sendable {
        let id: String
        let title: String
        let body: String
        let userInfo: [String: String]
    }
    private(set) var calls: [Call] = []
    func append(_ call: Call) { calls.append(call) }
    func snapshot() -> [Call] { calls }
    var count: Int { calls.count }
}

private struct StubAuthority: NotificationAuthority {
    let granted: Bool
    func requestAuth() async -> Bool { granted }
}

private struct StubPoster: NotificationPoster {
    let log: PosterCallLog
    func deliver(id: String, title: String, body: String, userInfo: [String: String]) async {
        await log.append(.init(id: id, title: title, body: body, userInfo: userInfo))
    }
}

@MainActor
final class MailNotifierTests: XCTestCase {

    private func makeFixture() throws -> (MailyDatabase, MessageRepository, ThreadRepository) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct", email: "u@x").insert($0) }
        let threads = ThreadRepository(queue: db.queue)
        return (db, MessageRepository(queue: db.queue), threads)
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 1.0,
        _ check: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await check()
    }

    func testStartWithoutPermissionIsNoop() async throws {
        let (_, repo, threads) = try makeFixture()
        try threads.upsert(MailThread(id: "t1", accountId: "acct"))
        // Pre-existing INBOX+UNREAD message before start().
        try repo.upsert(Message(
            id: "m1",
            threadId: "t1",
            accountId: "acct",
            fromAddr: "alice@x",
            subject: "hello",
            date: Date(),
            labelIds: ["INBOX", "UNREAD"]
        ))

        let log = PosterCallLog()
        let notifier = MailNotifier(
            messageRepo: repo,
            accountID: "acct",
            authority: StubAuthority(granted: false),
            poster: StubPoster(log: log)
        )

        await notifier.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let count = await log.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(notifier._notifiedIDsForTesting().isEmpty)
    }

    func testNewInboxUnreadAfterStartIsNotified() async throws {
        let (_, repo, threads) = try makeFixture()
        try threads.upsert(MailThread(id: "t1", accountId: "acct"))

        let log = PosterCallLog()
        let notifier = MailNotifier(
            messageRepo: repo,
            accountID: "acct",
            authority: StubAuthority(granted: true),
            poster: StubPoster(log: log)
        )
        await notifier.start()
        // Allow first (baseline) emission to land.
        try? await Task.sleep(nanoseconds: 50_000_000)

        try repo.upsert(Message(
            id: "m1",
            threadId: "t1",
            accountId: "acct",
            fromAddr: "alice@x",
            subject: "hello",
            date: Date(),
            labelIds: ["INBOX", "UNREAD"]
        ))

        let arrived = await waitUntilAsync { await log.count == 1 }
        XCTAssertTrue(arrived, "expected one delivery within timeout")

        let calls = await log.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "m1")
        XCTAssertEqual(calls.first?.title, "alice@x")
        XCTAssertEqual(calls.first?.body, "hello")
        XCTAssertEqual(calls.first?.userInfo["threadID"], "t1")
        XCTAssertTrue(notifier._notifiedIDsForTesting().contains("m1"))
    }

    func testNoDoubleNotificationOnLabelFlip() async throws {
        let (_, repo, threads) = try makeFixture()
        try threads.upsert(MailThread(id: "tA", accountId: "acct"))

        let log = PosterCallLog()
        let notifier = MailNotifier(
            messageRepo: repo,
            accountID: "acct",
            authority: StubAuthority(granted: true),
            poster: StubPoster(log: log)
        )
        await notifier.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Insert message A: INBOX+UNREAD -> should notify once.
        try repo.upsert(Message(
            id: "A",
            threadId: "tA",
            accountId: "acct",
            fromAddr: "a@x",
            subject: "subj",
            date: Date(),
            labelIds: ["INBOX", "UNREAD"]
        ))
        let first = await waitUntilAsync { await log.count == 1 }
        XCTAssertTrue(first, "expected initial delivery")

        // Remove UNREAD -> should leave the observation set; no new delivery.
        try repo.upsert(Message(
            id: "A",
            threadId: "tA",
            accountId: "acct",
            fromAddr: "a@x",
            subject: "subj",
            date: Date(),
            labelIds: ["INBOX"]
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Re-add UNREAD -> should NOT re-notify because A is still in notifiedIDs.
        try repo.upsert(Message(
            id: "A",
            threadId: "tA",
            accountId: "acct",
            fromAddr: "a@x",
            subject: "subj",
            date: Date(),
            labelIds: ["INBOX", "UNREAD"]
        ))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await log.count
        XCTAssertEqual(count, 1, "label flip must not re-notify")
    }

    func testSystemNotificationAuthorityReturnsFalseWithoutBundleID() async {
        // `swift test` runs in xctest.tool, not inside a real `.app` bundle.
        // The system authority must fail soft (returning false) instead of
        // throwing an uncatchable NSException from
        // UNUserNotificationCenter.current(). The test passing demonstrates
        // requestAuth() returns cleanly rather than crashing.
        let granted = await SystemNotificationAuthority().requestAuth()
        XCTAssertFalse(granted)
    }

    func testReadMessageDoesNotNotify() async throws {
        let (_, repo, threads) = try makeFixture()
        try threads.upsert(MailThread(id: "tr", accountId: "acct"))

        let log = PosterCallLog()
        let notifier = MailNotifier(
            messageRepo: repo,
            accountID: "acct",
            authority: StubAuthority(granted: true),
            poster: StubPoster(log: log)
        )
        await notifier.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        try repo.upsert(Message(
            id: "r1",
            threadId: "tr",
            accountId: "acct",
            fromAddr: "b@x",
            subject: "read-only",
            date: Date(),
            labelIds: ["INBOX"] // no UNREAD
        ))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await log.count
        XCTAssertEqual(count, 0)
    }
}
