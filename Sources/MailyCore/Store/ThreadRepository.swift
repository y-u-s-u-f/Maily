import Foundation
import GRDB

public struct ThreadRepository {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func upsert(_ thread: MailThread) throws {
        try queue.write { try thread.upsert($0) }
    }

    public func upsertAll(_ threads: [MailThread]) throws {
        try queue.write { db in
            for t in threads { try t.upsert(db) }
        }
    }

    public func thread(id: String) throws -> MailThread? {
        try queue.read { try MailThread.fetchOne($0, key: id) }
    }

    public func inbox(accountId: String, limit: Int = 200) throws -> [MailThread] {
        try queue.read { db in
            try MailThread
                .filter(Column("account_id") == accountId)
                .filter(sql: "json_array_length(label_ids_json) > 0 AND label_ids_json LIKE '%\"INBOX\"%'")
                .order(Column("last_message_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func observeInbox(accountId: String, limit: Int = 200) -> ValueObservation<ValueReducers.Fetch<[MailThread]>> {
        ValueObservation.tracking { db in
            try MailThread
                .filter(Column("account_id") == accountId)
                .filter(sql: "label_ids_json LIKE '%\"INBOX\"%'")
                .order(Column("last_message_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func delete(id: String) throws {
        _ = try queue.write { db in
            try MailThread.deleteOne(db, key: id)
        }
    }
}
