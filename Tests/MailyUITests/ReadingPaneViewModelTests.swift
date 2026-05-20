import XCTest
import GRDB
@testable import MailyCore
@testable import MailyUI

@MainActor
final class ReadingPaneViewModelTests: XCTestCase {

    private func makeFixture() throws -> (MailyDatabase, ThreadRepository, MessageRepository) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct", email: "u@x").insert($0) }
        return (db, ThreadRepository(queue: db.queue), MessageRepository(queue: db.queue))
    }

    func testInitialStateIsEmpty() throws {
        let (_, tRepo, mRepo) = try makeFixture()
        let vm = ReadingPaneViewModel(accountID: "acct", threadRepo: tRepo, messageRepo: mRepo)
        XCTAssertNil(vm.thread)
        XCTAssertEqual(vm.messages, [])
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.loadError)
    }

    func testSetSelectionLoadsThreadAndMessagesInDateAscOrder() async throws {
        let (_, tRepo, mRepo) = try makeFixture()
        let now = Date()
        try tRepo.upsert(MailThread(id: "t1", accountId: "acct", subject: "Hello"))
        // Insert out-of-order on purpose.
        try mRepo.upsertAll([
            Message(id: "m2", threadId: "t1", accountId: "acct", date: now.addingTimeInterval(60)),
            Message(id: "m1", threadId: "t1", accountId: "acct", date: now),
            Message(id: "m3", threadId: "t1", accountId: "acct", date: now.addingTimeInterval(120)),
        ])

        let vm = ReadingPaneViewModel(accountID: "acct", threadRepo: tRepo, messageRepo: mRepo)
        await vm.setSelection("t1")

        XCTAssertEqual(vm.thread?.id, "t1")
        XCTAssertEqual(vm.thread?.subject, "Hello")
        XCTAssertEqual(vm.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.loadError)
    }

    func testSetSelectionNilClearsState() async throws {
        let (_, tRepo, mRepo) = try makeFixture()
        try tRepo.upsert(MailThread(id: "t1", accountId: "acct", subject: "Hello"))
        try mRepo.upsert(Message(id: "m1", threadId: "t1", accountId: "acct", date: Date()))

        let vm = ReadingPaneViewModel(accountID: "acct", threadRepo: tRepo, messageRepo: mRepo)
        await vm.setSelection("t1")
        XCTAssertNotNil(vm.thread)
        XCTAssertFalse(vm.messages.isEmpty)

        await vm.setSelection(nil)
        XCTAssertNil(vm.thread)
        XCTAssertEqual(vm.messages, [])
        XCTAssertNil(vm.loadError)
        XCTAssertFalse(vm.isLoading)
    }

    func testSetSelectionUnknownIDProducesNotFoundError() async throws {
        let (_, tRepo, mRepo) = try makeFixture()
        let vm = ReadingPaneViewModel(accountID: "acct", threadRepo: tRepo, messageRepo: mRepo)

        await vm.setSelection("missing")

        XCTAssertEqual(vm.loadError, "Thread not found")
        XCTAssertNil(vm.thread)
        XCTAssertEqual(vm.messages, [])
        XCTAssertFalse(vm.isLoading)
    }

    func testRapidSelectionLatestWins() async throws {
        let (_, tRepo, mRepo) = try makeFixture()
        try tRepo.upsertAll([
            MailThread(id: "a", accountId: "acct", subject: "A"),
            MailThread(id: "b", accountId: "acct", subject: "B"),
        ])
        try mRepo.upsertAll([
            Message(id: "ma", threadId: "a", accountId: "acct", date: Date()),
            Message(id: "mb", threadId: "b", accountId: "acct", date: Date()),
        ])

        let vm = ReadingPaneViewModel(accountID: "acct", threadRepo: tRepo, messageRepo: mRepo)

        // Kick off the first; do not await it.
        Task { await vm.setSelection("a") }
        // Immediately fire the second and await it.
        await vm.setSelection("b")

        XCTAssertEqual(vm.thread?.id, "b")
        XCTAssertEqual(vm.messages.map(\.id), ["mb"])
        XCTAssertNil(vm.loadError)
        XCTAssertFalse(vm.isLoading)
    }

    func testEmptyThreadWithNoMessages() async throws {
        let (_, tRepo, mRepo) = try makeFixture()
        try tRepo.upsert(MailThread(id: "t1", accountId: "acct", subject: "Empty"))

        let vm = ReadingPaneViewModel(accountID: "acct", threadRepo: tRepo, messageRepo: mRepo)
        await vm.setSelection("t1")

        XCTAssertEqual(vm.thread?.id, "t1")
        XCTAssertEqual(vm.messages, [])
        XCTAssertNil(vm.loadError)
        XCTAssertFalse(vm.isLoading)
    }
}
