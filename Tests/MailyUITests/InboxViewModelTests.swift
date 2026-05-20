import XCTest
import Combine
import GRDB
@testable import MailyCore
@testable import MailyUI

@MainActor
final class InboxViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private func makeFixture() throws -> (MailyDatabase, ThreadRepository) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct", email: "u@x").insert($0) }
        return (db, ThreadRepository(queue: db.queue))
    }

    private func waitForEmission(
        _ vm: InboxViewModel,
        description: String,
        where predicate: @escaping ([MailThread]) -> Bool,
        timeout: TimeInterval = 2
    ) {
        let exp = expectation(description: description)
        var fulfilled = false
        vm.$threads
            .dropFirst() // drop initial empty
            .sink { threads in
                if !fulfilled, predicate(threads) {
                    fulfilled = true
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)
        wait(for: [exp], timeout: timeout)
    }

    func testInsertedThreadAppearsInViewModel() throws {
        let (_, repo) = try makeFixture()
        let vm = InboxViewModel(repository: repo, accountID: "acct")

        try repo.upsert(MailThread(id: "t1", accountId: "acct", subject: "hello"))

        waitForEmission(vm, description: "insert") { $0.map(\.id) == ["t1"] }
        XCTAssertEqual(vm.threads.first?.subject, "hello")
    }

    func testUpdatedSnippetReflectsInViewModel() throws {
        let (_, repo) = try makeFixture()
        try repo.upsert(MailThread(id: "t1", accountId: "acct", snippet: "old"))
        let vm = InboxViewModel(repository: repo, accountID: "acct")

        try repo.upsert(MailThread(id: "t1", accountId: "acct", snippet: "new"))

        waitForEmission(vm, description: "update") { threads in
            threads.first?.snippet == "new"
        }
    }

    func testDeletedThreadRemovedFromViewModel() throws {
        let (_, repo) = try makeFixture()
        try repo.upsert(MailThread(id: "t1", accountId: "acct"))
        let vm = InboxViewModel(repository: repo, accountID: "acct")

        try repo.delete(id: "t1")

        waitForEmission(vm, description: "delete") { $0.isEmpty }
    }

    func testThreadsOrderedByLastMessageAtDescending() throws {
        let (_, repo) = try makeFixture()
        let now = Date()
        try repo.upsertAll([
            MailThread(id: "old",   accountId: "acct", lastMessageAt: now.addingTimeInterval(-7200)),
            MailThread(id: "newest", accountId: "acct", lastMessageAt: now),
            MailThread(id: "mid",   accountId: "acct", lastMessageAt: now.addingTimeInterval(-3600)),
        ])

        let vm = InboxViewModel(repository: repo, accountID: "acct")

        waitForEmission(vm, description: "ordered") { threads in
            threads.map(\.id) == ["newest", "mid", "old"]
        }
    }

    func testViewModelScopesToAccount() throws {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write {
            try Account(id: "acct", email: "u@x").insert($0)
            try Account(id: "other", email: "o@x").insert($0)
        }
        let repo = ThreadRepository(queue: db.queue)
        try repo.upsertAll([
            MailThread(id: "mine", accountId: "acct"),
            MailThread(id: "theirs", accountId: "other"),
        ])

        let vm = InboxViewModel(repository: repo, accountID: "acct")

        waitForEmission(vm, description: "scoped") { $0.map(\.id) == ["mine"] }
    }
}
