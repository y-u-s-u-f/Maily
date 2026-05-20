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
}
