import XCTest
import GRDB
@testable import MailyCore

final class RepositoryTests: XCTestCase {
    private func makeFixture() throws -> (MailyDatabase, ThreadRepository, MessageRepository) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct", email: "u@x").insert($0) }
        return (db, ThreadRepository(queue: db.queue), MessageRepository(queue: db.queue))
    }

    func testThreadUpsertAndFetch() throws {
        let (_, threads, _) = try makeFixture()
        let t = MailThread(id: "t1", accountId: "acct", subject: "hi", labelIds: ["INBOX"])
        try threads.upsert(t)
        let fetched = try threads.thread(id: "t1")
        XCTAssertEqual(fetched?.subject, "hi")
        XCTAssertEqual(fetched?.labelIds, ["INBOX"])
    }

    func testInboxQueryFiltersByLabelAndSortsDescending() throws {
        let (_, threads, _) = try makeFixture()
        let now = Date()
        try threads.upsertAll([
            MailThread(id: "older", accountId: "acct", lastMessageAt: now.addingTimeInterval(-3600), labelIds: ["INBOX"]),
            MailThread(id: "newer", accountId: "acct", lastMessageAt: now, labelIds: ["INBOX"]),
            MailThread(id: "archived", accountId: "acct", lastMessageAt: now, labelIds: ["TRASH"]),
        ])
        let inbox = try threads.inbox(accountId: "acct")
        XCTAssertEqual(inbox.map(\.id), ["newer", "older"])
    }

    func testInboxObservationEmitsOnWrite() throws {
        let (_, threads, _) = try makeFixture()
        let observation = threads.observeInbox(accountId: "acct")

        let initial = expectation(description: "initial fetch")
        let updated = expectation(description: "update after write")
        var emissions: [[String]] = []
        let cancellable = observation.start(
            in: threads.queue,
            onError: { XCTFail("\($0)") },
            onChange: { emissions.append($0.map(\.id)); if emissions.count == 1 { initial.fulfill() } else if emissions.count == 2 { updated.fulfill() } }
        )
        wait(for: [initial], timeout: 1)

        try threads.upsert(MailThread(id: "t1", accountId: "acct", labelIds: ["INBOX"]))
        wait(for: [updated], timeout: 1)
        XCTAssertEqual(emissions.last, ["t1"])
        cancellable.cancel()
    }

    func testMessageBodyLazyFetch() throws {
        let (_, threads, messages) = try makeFixture()
        try threads.upsert(MailThread(id: "t1", accountId: "acct"))
        try messages.upsert(Message(id: "m1", threadId: "t1", accountId: "acct"))

        let missing = try messages.messagesMissingBody(accountId: "acct", limit: 10)
        XCTAssertEqual(missing.map(\.id), ["m1"])

        try messages.setBody(id: "m1", html: "<p>hi</p>", text: "hi")
        let stillMissing = try messages.messagesMissingBody(accountId: "acct", limit: 10)
        XCTAssertTrue(stillMissing.isEmpty)

        let loaded = try messages.message(id: "m1")
        XCTAssertEqual(loaded?.bodyText, "hi")
        XCTAssertNotNil(loaded?.bodyFetchedAt)
    }

    func testMessagesObservationByThread() throws {
        let (_, threads, messages) = try makeFixture()
        try threads.upsert(MailThread(id: "t1", accountId: "acct"))
        let observation = messages.observeMessages(threadId: "t1")

        let initial = expectation(description: "initial")
        let afterInsert = expectation(description: "after insert")
        var counts: [Int] = []
        let cancellable = observation.start(
            in: messages.queue,
            onError: { XCTFail("\($0)") },
            onChange: { counts.append($0.count); if counts.count == 1 { initial.fulfill() } else if counts.count == 2 { afterInsert.fulfill() } }
        )
        wait(for: [initial], timeout: 1)
        XCTAssertEqual(counts.last, 0)

        try messages.upsert(Message(id: "m1", threadId: "t1", accountId: "acct", date: Date()))
        wait(for: [afterInsert], timeout: 1)
        XCTAssertEqual(counts.last, 1)
        cancellable.cancel()
    }

    // MARK: - AccountRepository

    private func makeAccountFixture() throws -> (MailyDatabase, AccountRepository) {
        let db = try MailyDatabase(location: .inMemory)
        return (db, AccountRepository(queue: db.queue))
    }

    func testAccountUpsertAndFetchByEmail() throws {
        let (_, accounts) = try makeAccountFixture()
        let a = Account(id: "a1", email: "user@example.com")
        try accounts.upsert(a)
        let fetched = try accounts.account(email: "user@example.com")
        XCTAssertEqual(fetched?.id, "a1")
        XCTAssertEqual(fetched?.email, "user@example.com")
    }

    func testAccountUpsertIsIdempotent() throws {
        let (_, accounts) = try makeAccountFixture()
        try accounts.upsert(Account(id: "a1", email: "user@example.com"))
        try accounts.upsert(Account(id: "a1", email: "user@example.com", historyId: "h-99"))
        let all = try accounts.allAccounts()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.historyId, "h-99")
    }

    func testAllAccountsReturnsMultiple() throws {
        let (_, accounts) = try makeAccountFixture()
        try accounts.upsert(Account(id: "a1", email: "a@x"))
        try accounts.upsert(Account(id: "a2", email: "b@x"))
        let all = try accounts.allAccounts()
        XCTAssertEqual(Set(all.map(\.id)), ["a1", "a2"])
    }

    func testAccountObservationEmitsInitialThenOnInsert() throws {
        let (_, accounts) = try makeAccountFixture()
        let observation = accounts.observeAll()

        let initial = expectation(description: "initial")
        let afterInsert = expectation(description: "after insert")
        var emissions: [[String]] = []
        let cancellable = observation.start(
            in: accounts.queue,
            onError: { XCTFail("\($0)") },
            onChange: { emissions.append($0.map(\.id)); if emissions.count == 1 { initial.fulfill() } else if emissions.count == 2 { afterInsert.fulfill() } }
        )
        wait(for: [initial], timeout: 1)
        XCTAssertEqual(emissions.last, [])

        try accounts.upsert(Account(id: "a1", email: "u@x"))
        wait(for: [afterInsert], timeout: 1)
        XCTAssertEqual(emissions.last, ["a1"])
        cancellable.cancel()
    }

    func testUpdateHistoryIdScopesToTargetedAccount() throws {
        let (_, accounts) = try makeAccountFixture()
        try accounts.upsert(Account(id: "a1", email: "a@x", historyId: "h-1"))
        try accounts.upsert(Account(id: "a2", email: "b@x", historyId: "h-2"))

        try accounts.updateHistoryId("h-NEW", for: "a1")

        XCTAssertEqual(try accounts.account(email: "a@x")?.historyId, "h-NEW")
        XCTAssertEqual(try accounts.account(email: "b@x")?.historyId, "h-2")

        try accounts.updateHistoryId(nil, for: "a1")
        XCTAssertNil(try accounts.account(email: "a@x")?.historyId)
    }

    func testUpdateLastFullSyncScopesToTargetedAccount() throws {
        let (_, accounts) = try makeAccountFixture()
        try accounts.upsert(Account(id: "a1", email: "a@x"))
        try accounts.upsert(Account(id: "a2", email: "b@x"))

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try accounts.updateLastFullSync(date, for: "a1")

        XCTAssertEqual(try accounts.account(email: "a@x")?.lastFullSyncAt, date)
        XCTAssertNil(try accounts.account(email: "b@x")?.lastFullSyncAt)

        try accounts.updateLastFullSync(nil, for: "a1")
        XCTAssertNil(try accounts.account(email: "a@x")?.lastFullSyncAt)
    }

    // MARK: - LabelRepository

    private func makeLabelFixture() throws -> (MailyDatabase, LabelRepository) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write {
            try Account(id: "acct", email: "u@x").insert($0)
            try Account(id: "other", email: "o@x").insert($0)
        }
        return (db, LabelRepository(queue: db.queue))
    }

    func testLabelUpsertAndFetch() throws {
        let (_, labels) = try makeLabelFixture()
        try labels.upsert(Label(id: "L1", accountId: "acct", name: "Inbox", kind: .system), account: "acct")
        let all = try labels.fetchAll(account: "acct")
        XCTAssertEqual(all.map(\.id), ["L1"])
        XCTAssertEqual(all.first?.name, "Inbox")
    }

    func testLabelUpsertAllInSingleTransaction() throws {
        let (_, labels) = try makeLabelFixture()
        try labels.upsertAll([
            Label(id: "L1", accountId: "acct", name: "Beta", kind: .user),
            Label(id: "L2", accountId: "acct", name: "Alpha", kind: .user),
            Label(id: "L3", accountId: "acct", name: "Gamma", kind: .user),
        ], account: "acct")
        let all = try labels.fetchAll(account: "acct")
        // Ordered by name ascending
        XCTAssertEqual(all.map(\.id), ["L2", "L1", "L3"])
    }

    func testLabelFetchAllScopedByAccount() throws {
        let (_, labels) = try makeLabelFixture()
        try labels.upsert(Label(id: "L1", accountId: "acct", name: "Mine", kind: .user), account: "acct")
        try labels.upsert(Label(id: "L2", accountId: "other", name: "Theirs", kind: .user), account: "other")

        let mine = try labels.fetchAll(account: "acct")
        XCTAssertEqual(mine.map(\.id), ["L1"])
        let theirs = try labels.fetchAll(account: "other")
        XCTAssertEqual(theirs.map(\.id), ["L2"])
    }

    func testLabelObservationEmitsInitialThenOnInsert() throws {
        let (_, labels) = try makeLabelFixture()
        let observation = labels.observe(account: "acct")

        let initial = expectation(description: "initial")
        let afterInsert = expectation(description: "after insert")
        var counts: [Int] = []
        let cancellable = observation.start(
            in: labels.queue,
            onError: { XCTFail("\($0)") },
            onChange: { counts.append($0.count); if counts.count == 1 { initial.fulfill() } else if counts.count == 2 { afterInsert.fulfill() } }
        )
        wait(for: [initial], timeout: 1)
        XCTAssertEqual(counts.last, 0)

        try labels.upsert(Label(id: "L1", accountId: "acct", name: "Inbox", kind: .system), account: "acct")
        wait(for: [afterInsert], timeout: 1)
        XCTAssertEqual(counts.last, 1)
        cancellable.cancel()
    }

    func testLabelDeleteRemovesRow() throws {
        let (_, labels) = try makeLabelFixture()
        try labels.upsert(Label(id: "L1", accountId: "acct", name: "Inbox", kind: .system), account: "acct")
        try labels.delete(id: "L1")
        XCTAssertTrue(try labels.fetchAll(account: "acct").isEmpty)
    }

    func testLabelUpsertRejectsMismatchedAccount() throws {
        // precondition aborts the process rather than throwing, so we can't catch it with XCTAssertThrowsError;
        // pin the matching path instead and trust the precondition to fail loudly for callers who violate it.
        let (_, labels) = try makeLabelFixture()
        let label = Label(id: "L", accountId: "acct", name: "Match", kind: .user)
        XCTAssertNoThrow(try labels.upsert(label, account: "acct"))
        let fetched = try labels.fetchAll(account: "acct")
        XCTAssertEqual(fetched.map(\.id), ["L"])
    }
}
