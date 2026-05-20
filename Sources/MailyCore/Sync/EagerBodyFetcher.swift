import Foundation
import GRDB
import OSLog

/// Eagerly fetches full message bodies for the top-`limit` most-recent INBOX
/// threads after metadata sync, so opening a thread in the reading pane is
/// instant on first run.
///
/// Pulls candidate ids from the local DB (INBOX + `body_fetched_at IS NULL`,
/// newest first), batches `format=full` GETs against Gmail in `chunkSize`-id
/// chunks, decodes the payload tree, and updates `body_html` / `body_text` /
/// `body_fetched_at` in a single per-chunk transaction.
///
/// Per-subresponse 4xx/5xx and decode failures are logged and skipped — they
/// do not abort the chunk or the run.
public actor EagerBodyFetcher {

    private static let log = Logger(subsystem: "com.maily.core", category: "EagerBodyFetcher")

    private let client: GmailClient
    private let db: any DatabaseWriter
    private let accountID: String
    private let limit: Int
    private let chunkSize: Int
    private let onProgress: @Sendable (Int) -> Void

    public init(
        client: GmailClient,
        db: any DatabaseWriter,
        accountID: String,
        limit: Int = 200,
        chunkSize: Int = 50,
        onProgress: @Sendable @escaping (Int) -> Void = { _ in }
    ) {
        self.client = client
        self.db = db
        self.accountID = accountID
        self.limit = limit
        self.chunkSize = chunkSize
        self.onProgress = onProgress
    }

    /// Find the top-`limit` most-recent INBOX messages with no body yet,
    /// fetch them in batched `format=full` chunks, and update each row.
    public func fetchTopInbox() async throws {
        let candidateIDs = try await loadCandidateIDs()
        guard !candidateIDs.isEmpty else { return }

        var index = 0
        while index < candidateIDs.count {
            let end = min(index + chunkSize, candidateIDs.count)
            let chunk = Array(candidateIDs[index..<end])
            try await fetchChunk(chunk)
            index = end
        }
    }

    // MARK: - Per-chunk

    private func loadCandidateIDs() async throws -> [String] {
        let acctID = accountID
        let lim = limit
        return try await db.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM messages
                WHERE account_id = ?
                  AND body_fetched_at IS NULL
                  AND label_ids_json LIKE '%"INBOX"%'
                ORDER BY date DESC
                LIMIT ?
                """,
                arguments: [acctID, lim]
            )
        }
    }

    private func fetchChunk(_ ids: [String]) async throws {
        let subrequests = ids.map { id in
            BatchSubrequest(method: "GET", path: Self.fullPath(userID: client.userID, messageID: id))
        }
        let responses = try await client.batch(subrequests)

        // Decode each subresponse, skipping (with logging) failures.
        var decoded: [DecodedBody] = []
        decoded.reserveCapacity(responses.count)

        for (i, sub) in responses.enumerated() {
            let id = ids[i]
            if sub.status != 200 {
                Self.log.error("batch subresponse failed id=\(id, privacy: .public) status=\(sub.status, privacy: .public)")
                continue
            }
            let msg: GmailMessage
            do {
                msg = try GmailClient.decoder.decode(GmailMessage.self, from: sub.body)
            } catch {
                Self.log.error("batch subresponse decode failed id=\(id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                continue
            }
            let (html, text) = Self.extractBodies(from: msg.payload)
            decoded.append(DecodedBody(id: id, bodyHtml: html, bodyText: text))
        }

        if decoded.isEmpty {
            onProgress(0)
            return
        }

        let now = Date()
        let snapshot = decoded
        let updatedCount = try await db.write { db -> Int in
            var count = 0
            for d in snapshot {
                try db.execute(
                    sql: """
                    UPDATE messages
                    SET body_html = ?, body_text = ?, body_fetched_at = ?
                    WHERE id = ?
                    """,
                    arguments: [d.bodyHtml, d.bodyText, now, d.id]
                )
                count += db.changesCount
            }
            return count
        }

        onProgress(updatedCount)
    }

    // MARK: - Types

    private struct DecodedBody: Sendable {
        let id: String
        let bodyHtml: String?
        let bodyText: String?
    }

    // MARK: - Path

    private static func fullPath(userID: String, messageID: String) -> String {
        "/gmail/v1/users/\(userID)/messages/\(messageID)?format=full"
    }

    // MARK: - Body extraction

    /// Walk a `MessagePayload` tree and pick out plain text and HTML bodies.
    ///
    /// Preference order (per spec):
    /// 1. First `text/plain` part with non-nil `body.data` → decode as `bodyText`.
    ///    If a `text/html` twin also exists in the same payload tree, also
    ///    decode it (raw, not stripped) into `bodyHtml`. `multipart/alternative`
    ///    messages almost always carry both, and the reading pane needs HTML.
    /// 2. Else first `text/html` part with non-nil `body.data` → decode HTML,
    ///    store raw as `bodyHtml`, also store HTML-stripped text as `bodyText`.
    /// 3. Else if root payload itself has `body.data`, use its `mimeType` to
    ///    decide which slot to fill (single-part message).
    static func extractBodies(from payload: MessagePayload?) -> (html: String?, text: String?) {
        guard let payload else { return (nil, nil) }

        if let plainData = firstPart(payload, mimeType: "text/plain")?.body?.data,
           let decoded = decodeBase64URL(plainData) {
            // Preserve a sibling text/html part verbatim if one is present so
            // the reading pane has rich HTML to render.
            let html: String?
            if let htmlData = firstPart(payload, mimeType: "text/html")?.body?.data {
                html = decodeBase64URL(htmlData)
            } else {
                html = nil
            }
            return (html, decoded)
        }

        if let htmlPart = firstPart(payload, mimeType: "text/html"),
           let htmlData = htmlPart.body?.data,
           let html = decodeBase64URL(htmlData) {
            return (html, stripHTML(html))
        }

        // Fallback: single-part root with inline body.data.
        if let rootData = payload.body?.data,
           let decoded = decodeBase64URL(rootData) {
            let mime = payload.mimeType?.lowercased() ?? ""
            if mime.hasPrefix("text/html") {
                return (decoded, stripHTML(decoded))
            }
            if mime.hasPrefix("text/") || mime.isEmpty {
                return (nil, decoded)
            }
        }

        return (nil, nil)
    }

    /// Depth-first search for the first descendant (including the payload
    /// itself) whose `mimeType` matches case-insensitively.
    private static func firstPart(_ payload: MessagePayload, mimeType target: String) -> MessagePayload? {
        let target = target.lowercased()
        if payload.mimeType?.lowercased() == target { return payload }
        if let parts = payload.parts {
            for p in parts {
                if let hit = firstPart(p, mimeType: target) { return hit }
            }
        }
        return nil
    }

    /// Decode a Gmail base64url-encoded body. Gmail strips padding and (for
    /// large bodies) may interleave whitespace/newlines; we strip whitespace,
    /// re-pad to a multiple of 4, and convert `-/_` back to `+//`. Decoding
    /// uses `.ignoreUnknownCharacters` so any residual non-base64 bytes are
    /// tolerated instead of failing the whole row.
    static func decodeBase64URL(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+")
        b = b.replacingOccurrences(of: "_", with: "/")
        // Padding length must be computed against the count of base64
        // characters only — strip whitespace first so we don't over-pad.
        b.removeAll { $0.isWhitespace || $0.isNewline }
        let rem = b.count % 4
        if rem != 0 {
            b.append(String(repeating: "=", count: 4 - rem))
        }
        guard let data = Data(base64Encoded: b, options: [.ignoreUnknownCharacters]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Minimal HTML → text: strip tags, collapse whitespace, trim.
    static func stripHTML(_ html: String) -> String {
        // Replace any tag with a single space.
        let noTags = html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        // Collapse runs of whitespace (including newlines).
        let collapsed = noTags.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
