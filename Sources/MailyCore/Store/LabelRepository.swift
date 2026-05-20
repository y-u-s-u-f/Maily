import Foundation
import GRDB

public struct LabelRepository {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    // The `account` arg scopes the operation and is force-assigned onto the
    // label's accountId to prevent cross-account leakage from miswired callers.
    public func upsert(_ label: Label, account: String) throws {
        var scoped = label
        scoped.accountId = account
        try queue.write { try scoped.upsert($0) }
    }

    public func upsertAll(_ labels: [Label], account: String) throws {
        try queue.write { db in
            for l in labels {
                var scoped = l
                scoped.accountId = account
                try scoped.upsert(db)
            }
        }
    }

    public func fetchAll(account: String) throws -> [Label] {
        try queue.read { db in
            try Label
                .filter(Column("account_id") == account)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    public func observe(account: String) -> ValueObservation<ValueReducers.Fetch<[Label]>> {
        ValueObservation.tracking { db in
            try Label
                .filter(Column("account_id") == account)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    public func delete(id: String) throws {
        _ = try queue.write { db in
            try Label.deleteOne(db, key: id)
        }
    }
}
