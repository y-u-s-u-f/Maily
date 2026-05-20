import Foundation
import GRDB

public struct AccountRepository {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func upsert(_ account: Account) throws {
        try queue.write { try account.upsert($0) }
    }

    public func account(email: String) throws -> Account? {
        try queue.read { db in
            try Account
                .filter(Column("email") == email)
                .fetchOne(db)
        }
    }

    public func allAccounts() throws -> [Account] {
        try queue.read { db in
            try Account
                .order(Column("email"))
                .fetchAll(db)
        }
    }

    public func observeAll() -> ValueObservation<ValueReducers.Fetch<[Account]>> {
        ValueObservation.tracking { db in
            try Account
                .order(Column("email"))
                .fetchAll(db)
        }
    }

    public func updateHistoryId(_ historyId: String?, for accountId: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE accounts SET history_id = ? WHERE id = ?",
                arguments: [historyId, accountId]
            )
        }
    }

    public func updateLastFullSync(_ date: Date?, for accountId: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE accounts SET last_full_sync_at = ? WHERE id = ?",
                arguments: [date, accountId]
            )
        }
    }
}
