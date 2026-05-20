import Foundation
import GRDB
import OSLog

/// Fetches Gmail message metadata in 100-id chunks via `/batch/gmail/v1` and
/// upserts the resulting messages + threads into the local database, one
/// transaction per chunk.
///
/// Failures inside a chunk (non-200 subresponse, decoding error) are logged
/// and skipped — they do not abort the rest of the chunk or the run.
public actor MetadataBatchSyncer {

    private static let log = Logger(subsystem: "com.maily.core", category: "MetadataBatchSyncer")
    private static let metadataHeaders = ["From", "To", "Cc", "Bcc", "Subject", "Date"]

    private let client: GmailClient
    private let db: any DatabaseWriter
    private let accountID: String
    private let chunkSize: Int
    private let onChunk: @Sendable (Int) -> Void

    public init(
        client: GmailClient,
        db: any DatabaseWriter,
        accountID: String,
        chunkSize: Int = 100,
        onChunk: @Sendable @escaping (Int) -> Void = { _ in }
    ) {
        self.client = client
        self.db = db
        self.accountID = accountID
        self.chunkSize = chunkSize
        self.onChunk = onChunk
    }

    /// Sync the given `messages` by fetching `format=metadata` in chunks and
    /// upserting each chunk into the database. Returns after every chunk has
    /// been processed.
    public func sync(_ messages: [MessageRef]) async throws {
        guard !messages.isEmpty else { return }

        var index = 0
        while index < messages.count {
            let end = min(index + chunkSize, messages.count)
            let chunk = Array(messages[index..<end])
            try await syncChunk(chunk)
            index = end
        }
    }

    // MARK: - Per-chunk

    private func syncChunk(_ chunk: [MessageRef]) async throws {
        let subrequests = chunk.map { ref in
            BatchSubrequest(method: "GET", path: Self.metadataPath(userID: client.userID, messageID: ref.id))
        }
        let responses = try await client.batch(subrequests)

        // Decode each subresponse, skipping (with logging) failures.
        var decoded: [GmailMessage] = []
        decoded.reserveCapacity(responses.count)
        for (i, sub) in responses.enumerated() {
            let id = chunk[i].id
            if sub.status != 200 {
                Self.log.error("batch subresponse failed id=\(id, privacy: .public) status=\(sub.status, privacy: .public)")
                continue
            }
            do {
                let msg = try GmailClient.decoder.decode(GmailMessage.self, from: sub.body)
                decoded.append(msg)
            } catch {
                Self.log.error("batch subresponse decode failed id=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                continue
            }
        }

        if decoded.isEmpty {
            onChunk(0)
            return
        }

        // NOTE: Thread aggregates (unreadCount, messageCount, lastMessageAt, snippet, subject)
        // are chunk-local — a thread spanning multiple chunks will have its row overwritten
        // by each chunk's view. True per-thread reconciliation is deferred to a later sync stage.
        struct ThreadAccumulator {
            var unreadCount: Int = 0
            var messageCount: Int = 0
            var lastMessageAt: Date? = nil
            var snippet: String? = nil
            var subject: String? = nil
        }

        var accumByID: [String: ThreadAccumulator] = [:]
        for msg in decoded {
            var acc = accumByID[msg.threadId] ?? ThreadAccumulator()
            acc.messageCount += 1
            if (msg.labelIds ?? []).contains("UNREAD") {
                acc.unreadCount += 1
            }
            let msgDate = Self.internalDateToDate(msg.internalDate)
            // "Newest" wins for snippet/subject/lastMessageAt. A nil-dated
            // message only wins if no dated message has been seen yet.
            let shouldReplace: Bool
            switch (msgDate, acc.lastMessageAt) {
            case let (newDate?, existingDate?):
                shouldReplace = newDate >= existingDate
            case (.some, .none):
                shouldReplace = true
            case (.none, .none):
                // No dated message seen yet — let the latest nil-dated message
                // populate snippet/subject so we don't leave the row empty.
                shouldReplace = acc.snippet == nil && acc.subject == nil && acc.messageCount == 1
            case (.none, .some):
                shouldReplace = false
            }
            if shouldReplace {
                acc.lastMessageAt = msgDate
                acc.snippet = msg.snippet
                acc.subject = Self.header(msg, name: "Subject")
            }
            accumByID[msg.threadId] = acc
        }

        let threads: [MailThread] = accumByID.map { (threadId, acc) in
            MailThread(
                id: threadId,
                accountId: accountID,
                snippet: acc.snippet,
                subject: acc.subject,
                lastMessageAt: acc.lastMessageAt,
                unreadCount: acc.unreadCount,
                messageCount: acc.messageCount
            )
        }

        // Build message rows.
        let messageRows: [Message] = decoded.map { msg in
            Message(
                id: msg.id,
                threadId: msg.threadId,
                accountId: accountID,
                fromAddr: Self.header(msg, name: "From"),
                toAddrs: Self.headerList(msg, name: "To"),
                cc: Self.headerList(msg, name: "Cc"),
                bcc: Self.headerList(msg, name: "Bcc"),
                subject: Self.header(msg, name: "Subject"),
                snippet: msg.snippet,
                date: Self.internalDateToDate(msg.internalDate),
                labelIds: msg.labelIds ?? []
            )
        }

        try await db.write { db in
            // Threads first — messages have a FK on threads(id).
            for t in threads { try t.upsert(db) }
            for m in messageRows { try m.upsert(db) }
        }

        onChunk(decoded.count)
    }

    // MARK: - Helpers

    private static func metadataPath(userID: String, messageID: String) -> String {
        let headerQuery = metadataHeaders.map { "metadataHeaders=\($0)" }.joined(separator: "&")
        return "/gmail/v1/users/\(userID)/messages/\(messageID)?format=metadata&\(headerQuery)"
    }

    /// Case-insensitive lookup of the first header with the given name.
    private static func header(_ msg: GmailMessage, name: String) -> String? {
        guard let headers = msg.payload?.headers else { return nil }
        let target = name.lowercased()
        for h in headers where h.name.lowercased() == target {
            return h.value
        }
        return nil
    }

    /// Split a comma-separated header value, trim whitespace, drop empties.
    private static func headerList(_ msg: GmailMessage, name: String) -> [String] {
        guard let raw = header(msg, name: name) else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Gmail's `internalDate` is milliseconds-since-epoch as a string.
    private static func internalDateToDate(_ s: String?) -> Date? {
        guard let s, let ms = Int64(s) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}
