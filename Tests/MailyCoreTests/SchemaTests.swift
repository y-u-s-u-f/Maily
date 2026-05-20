import XCTest
import GRDB
@testable import MailyCore

final class SchemaTests: XCTestCase {
    private func makeDatabase() throws -> MailyDatabase {
        try MailyDatabase(location: .inMemory)
    }

    func testMigrationCreatesAllTables() throws {
        let db = try makeDatabase()
        let expected: Set<String> = [
            "accounts", "threads", "messages",
            "labels", "attachments", "pending_mutations"
        ]
        try db.queue.read { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
            )
            XCTAssertTrue(expected.isSubset(of: Set(names)), "missing tables: \(expected.subtracting(Set(names)))")
        }
    }

    func testForeignKeysEnforced() throws {
        let db = try makeDatabase()
        do {
            try db.queue.write { db in
                var thread = MailThread(id: "t1", accountId: "nope")
                try thread.insert(db)
            }
            XCTFail("expected FK violation")
        } catch {
            // FK violation expected
        }
    }

    func testAccountRoundTrip() throws {
        let db = try makeDatabase()
        let original = Account(id: "acct-1", email: "test@example.com", historyId: "42")
        try db.queue.write { try original.insert($0) }
        let fetched = try db.queue.read { try Account.fetchOne($0, key: "acct-1") }
        XCTAssertEqual(fetched, original)
    }

    func testThreadJSONArrayRoundTrip() throws {
        let db = try makeDatabase()
        try db.queue.write { db in
            try Account(id: "acct", email: "t@x").insert(db)
            var thread = MailThread(id: "thr", accountId: "acct", labelIds: ["INBOX", "UNREAD"])
            try thread.insert(db)
        }
        let fetched = try db.queue.read { try MailThread.fetchOne($0, key: "thr") }
        XCTAssertEqual(fetched?.labelIds, ["INBOX", "UNREAD"])
    }

    func testMessageFlagsBitmask() throws {
        let db = try makeDatabase()
        try db.queue.write { db in
            try Account(id: "a", email: "e@x").insert(db)
            try MailThread(id: "t", accountId: "a").insert(db)
            var m = Message(id: "m1", threadId: "t", accountId: "a", flags: [.starred, .sent])
            try m.insert(db)
        }
        let fetched = try db.queue.read { try Message.fetchOne($0, key: "m1") }
        XCTAssertEqual(fetched?.flags, [.starred, .sent])
        XCTAssertEqual(fetched?.flagsRaw, MessageFlags.starred.rawValue | MessageFlags.sent.rawValue)
    }

    func testPendingMutationAutoincrement() throws {
        let db = try makeDatabase()
        try db.queue.write { db in
            try Account(id: "a", email: "e@x").insert(db)
            var first = PendingMutation(accountId: "a", kind: .markRead, payloadJson: "{}")
            try first.insert(db)
            XCTAssertNotNil(first.id)

            var second = PendingMutation(accountId: "a", kind: .trash, payloadJson: "{}")
            try second.insert(db)
            XCTAssertNotNil(second.id)
            XCTAssertGreaterThan(second.id!, first.id!)
        }
    }

    func testInboxIndexUsedForSortQuery() throws {
        let db = try makeDatabase()
        try db.queue.read { db in
            let plan = try Row.fetchAll(
                db,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT id FROM threads
                WHERE account_id = 'x'
                ORDER BY last_message_at DESC
                """
            )
            let planText = plan.map { String(describing: $0) }.joined(separator: "\n")
            XCTAssertTrue(planText.contains("idx_threads_inbox"), "inbox query plan should use idx_threads_inbox; got:\n\(planText)")
        }
    }
}
