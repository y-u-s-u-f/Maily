import Foundation
import GRDB

enum Migrations {
    static func register(in queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    email TEXT NOT NULL UNIQUE,
                    oauth_refresh_token_ref TEXT,
                    history_id TEXT,
                    last_full_sync_at INTEGER
                );
            """)

            try db.execute(sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    snippet TEXT,
                    subject TEXT,
                    last_message_at INTEGER,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    message_count INTEGER NOT NULL DEFAULT 0,
                    label_ids_json TEXT NOT NULL DEFAULT '[]'
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_threads_inbox
                ON threads(account_id, last_message_at DESC);
            """)

            try db.execute(sql: """
                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    from_addr TEXT,
                    to_addrs_json TEXT NOT NULL DEFAULT '[]',
                    cc_json TEXT NOT NULL DEFAULT '[]',
                    bcc_json TEXT NOT NULL DEFAULT '[]',
                    subject TEXT,
                    snippet TEXT,
                    date INTEGER,
                    body_html TEXT,
                    body_text TEXT,
                    body_fetched_at INTEGER,
                    label_ids_json TEXT NOT NULL DEFAULT '[]',
                    flags INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_messages_thread_date
                ON messages(thread_id, date);
            """)

            try db.execute(sql: """
                CREATE TABLE labels (
                    id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    type TEXT NOT NULL,
                    color TEXT
                );
            """)

            try db.execute(sql: """
                CREATE TABLE attachments (
                    id TEXT PRIMARY KEY,
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    filename TEXT,
                    mime_type TEXT,
                    size INTEGER,
                    gmail_attachment_id TEXT,
                    local_path TEXT
                );
            """)

            try db.execute(sql: """
                CREATE TABLE pending_mutations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                );
            """)
            try db.execute(sql: """
                CREATE INDEX idx_pending_mutations_drain
                ON pending_mutations(account_id, created_at);
            """)
        }

        try migrator.migrate(queue)
    }
}
