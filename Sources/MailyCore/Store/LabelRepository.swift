import Foundation
import GRDB

public struct LabelRepository {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func upsert(_ label: Label, account: String) throws {
        precondition(label.accountId == account, "label.accountId must match account argument")
        try queue.write { try label.upsert($0) }
    }

    public func upsertAll(_ labels: [Label], account: String) throws {
        for l in labels {
            precondition(l.accountId == account, "label.accountId must match account argument")
        }
        try queue.write { db in
            for l in labels {
                try l.upsert(db)
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
