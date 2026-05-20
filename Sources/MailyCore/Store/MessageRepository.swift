import Foundation
import GRDB

public struct MessageRepository {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func upsert(_ message: Message) throws {
        try queue.write { try message.upsert($0) }
    }

    public func upsertAll(_ messages: [Message]) throws {
        try queue.write { db in
            for m in messages { try m.upsert(db) }
        }
    }

    public func message(id: String) throws -> Message? {
        try queue.read { try Message.fetchOne($0, key: id) }
    }

    public func messages(threadId: String) throws -> [Message] {
        try queue.read { db in
            try Message
                .filter(Column("thread_id") == threadId)
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    public func observeMessages(threadId: String) -> ValueObservation<ValueReducers.Fetch<[Message]>> {
        ValueObservation.tracking { db in
            try Message
                .filter(Column("thread_id") == threadId)
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    public func observeInboxUnread(accountId: String) -> ValueObservation<ValueReducers.Fetch<[Message]>> {
        ValueObservation.tracking { db in
            try Message
                .filter(Column("account_id") == accountId)
                .filter(sql: "label_ids_json LIKE '%\"INBOX\"%' AND label_ids_json LIKE '%\"UNREAD\"%'")
                .order(Column("date"))
                .fetchAll(db)
        }
    }

    public func messagesMissingBody(accountId: String, limit: Int) throws -> [Message] {
        try queue.read { db in
            try Message
                .filter(Column("account_id") == accountId)
                .filter(Column("body_fetched_at") == nil)
                .order(Column("date").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func setBody(id: String, html: String?, text: String?, fetchedAt: Date = .init()) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE messages
                SET body_html = ?, body_text = ?, body_fetched_at = ?
                WHERE id = ?
                """,
                arguments: [html, text, fetchedAt, id]
            )
        }
    }
}
