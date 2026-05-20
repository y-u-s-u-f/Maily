import Foundation
import GRDB

/// Long-running actor that polls `users.history.list` on a cadence
/// determined by app state and applies the diff to the local database.
///
/// One poll = one round of `users.history.list` (paged as needed) +
/// one `db.write { ... }` transaction that applies all mutations and
/// advances `account.history_id`.
///
/// On a `404` (historyId expired) it invokes `onHistoryExpired` and
/// returns without writing — the caller is expected to schedule a full
/// re-list (handled elsewhere).
public actor HistoryWatcher {

    public enum AppState: Sendable {
        case focused
        case background
        case closed
    }

    private let client: GmailClient
    private let db: any DatabaseWriter
    // Kept for API symmetry with the spec; all writes are inlined into the
    // single poll transaction below for atomicity, so this repo is unused.
    private let accountRepo: AccountRepository
    private let accountID: String
    private var state: AppState
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let onHistoryExpired: @Sendable () -> Void
    /// Callback fired after a successful poll. The Int is the number of
    /// `HistoryEntry` items applied during this poll.
    private let onPolled: @Sendable (Int) -> Void

    private var runTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var inFlight: Task<Void, Error>?

    public init(
        client: GmailClient,
        db: any DatabaseWriter,
        accountRepo: AccountRepository,
        accountID: String,
        state: AppState = .focused,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        onHistoryExpired: @escaping @Sendable () -> Void = {},
        onPolled: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.client = client
        self.db = db
        self.accountRepo = accountRepo
        self.accountID = accountID
        self.state = state
        self.sleeper = sleeper
        self.onHistoryExpired = onHistoryExpired
        self.onPolled = onPolled
    }

    public func updateState(_ state: AppState) async {
        self.state = state
        // Wake any in-progress sleep so the new cadence takes effect now,
        // rather than after the current sleep interval (up to 1h) elapses.
        sleepTask?.cancel()
    }

    public func start() async {
        // No-op if a run loop is already in flight — prevents double-start.
        if runTask != nil { return }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() async {
        guard let task = runTask else { return }
        task.cancel()
        sleepTask?.cancel()
        // Await completion BEFORE clearing runTask so a racing start() can't
        // spawn a second loop while this one is still winding down.
        _ = await task.value
        runTask = nil
    }

    /// Best-effort cleanup. Callers should still prefer explicit `stop()`.
    deinit {
        runTask?.cancel()
        sleepTask?.cancel()
    }

    /// Cancellable sleep — wraps the injected sleeper in a Task so
    /// `updateState` / `stop` can cut it short via `sleepTask?.cancel()`.
    private func sleep(_ interval: TimeInterval) async {
        let task = Task { await sleeper(interval) }
        sleepTask = task
        _ = await task.value
        sleepTask = nil
    }

    // MARK: - run loop

    private func runLoop() async {
        while !Task.isCancelled {
            let currentState = state
            if currentState == .closed {
                await sleep(3600)
                continue
            }
            do {
                try await pollOnce()
            } catch {
                print("HistoryWatcher poll error: \(error)")
            }
            // Re-sample state for cadence — updateState takes effect next iteration.
            let interval: TimeInterval
            switch state {
            case .focused: interval = 15
            case .background: interval = 300
            case .closed: interval = 3600
            }
            await sleep(interval)
        }
    }

    // MARK: - one poll

    public func pollOnce() async throws {
        // Coalesce overlapping callers — concurrent invocations await the
        // single in-flight poll rather than racing on the baseline read.
        if let existing = inFlight {
            try await existing.value
            return
        }
        let task = Task { try await performPoll() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    private func performPoll() async throws {
        // Read baseline history_id outside the write transaction.
        let baseline: String? = try await db.read { db in
            try Account.fetchOne(db, key: self.accountID)?.historyId
        }
        guard let startHistoryId = baseline else {
            // No baseline — can't diff. The full-sync watcher (M3-d) is
            // responsible for establishing one.
            return
        }

        // Page through history, collecting all entries and the final
        // historyId from the LAST page (which is what we should persist).
        var collected: [HistoryEntry] = []
        var finalHistoryId: String? = nil
        var pageToken: String? = nil

        do {
            repeat {
                let response = try await client.listHistory(
                    startHistoryId: startHistoryId,
                    historyTypes: ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"],
                    pageToken: pageToken
                )
                if let entries = response.history {
                    collected.append(contentsOf: entries)
                }
                finalHistoryId = response.historyId ?? finalHistoryId
                pageToken = response.nextPageToken
            } while pageToken != nil
        } catch AuthenticatedSessionError.http(let status, _) where status == 404 {
            onHistoryExpired()
            return
        }

        // Apply all mutations + advance history_id in a single transaction.
        let appliedCount = collected.count
        let entries = collected
        let newHistoryId = finalHistoryId
        try await db.write { [accountID] db in
            for entry in entries {
                try Self.apply(entry: entry, accountID: accountID, db: db)
            }
            if let newHistoryId {
                try db.execute(
                    sql: "UPDATE accounts SET history_id = ? WHERE id = ?",
                    arguments: [newHistoryId, accountID]
                )
            }
        }
        onPolled(appliedCount)
    }

    // MARK: - per-entry application

    private static func apply(entry: HistoryEntry, accountID: String, db: Database) throws {
        if let added = entry.messagesAdded {
            for mutation in added {
                try applyMessageAdded(mutation: mutation, accountID: accountID, db: db)
            }
        }
        if let deleted = entry.messagesDeleted {
            for mutation in deleted {
                try applyMessageDeleted(mutation: mutation, db: db)
            }
        }
        if let added = entry.labelsAdded {
            for mutation in added {
                try applyLabelsAdded(mutation: mutation, db: db)
            }
        }
        if let removed = entry.labelsRemoved {
            for mutation in removed {
                try applyLabelsRemoved(mutation: mutation, db: db)
            }
        }
    }

    private static func applyMessageAdded(
        mutation: HistoryMessageMutation,
        accountID: String,
        db: Database
    ) throws {
        let ref = mutation.message
        let labels = mutation.labelIds ?? []
        // Upsert thread (skeleton — body/headers backfilled by another watcher).
        // Preserve existing labels if the thread already exists.
        if let existing = try MailThread.fetchOne(db, key: ref.threadId) {
            var updated = existing
            updated.labelIds = existing.labelIds + labels.filter { !existing.labelIds.contains($0) }
            try updated.upsert(db)
        } else {
            let thread = MailThread(
                id: ref.threadId,
                accountId: accountID,
                labelIds: labels
            )
            try thread.upsert(db)
        }
        // Upsert message.
        if let existing = try Message.fetchOne(db, key: ref.id) {
            var updated = existing
            updated.labelIds = existing.labelIds + labels.filter { !existing.labelIds.contains($0) }
            try updated.upsert(db)
        } else {
            let message = Message(
                id: ref.id,
                threadId: ref.threadId,
                accountId: accountID,
                labelIds: labels
            )
            try message.upsert(db)
        }
        try recomputeCounts(threadId: ref.threadId, db: db)
    }

    private static func applyMessageDeleted(
        mutation: HistoryMessageMutation,
        db: Database
    ) throws {
        let ref = mutation.message
        _ = try Message.deleteOne(db, key: ref.id)
        try recomputeCounts(threadId: ref.threadId, db: db)
    }

    private static func applyLabelsAdded(
        mutation: HistoryMessageMutation,
        db: Database
    ) throws {
        let ref = mutation.message
        let toAdd = mutation.labelIds ?? []
        guard var message = try Message.fetchOne(db, key: ref.id) else {
            return  // unknown message — skeleton not yet present; skip
        }
        message.labelIds = message.labelIds + toAdd.filter { !message.labelIds.contains($0) }
        try message.update(db)
        if toAdd.contains("UNREAD") {
            try recomputeUnreadCount(threadId: ref.threadId, db: db)
        }
    }

    private static func applyLabelsRemoved(
        mutation: HistoryMessageMutation,
        db: Database
    ) throws {
        let ref = mutation.message
        let toRemove = Set(mutation.labelIds ?? [])
        guard var message = try Message.fetchOne(db, key: ref.id) else { return }
        let remaining = message.labelIds.filter { !toRemove.contains($0) }
        message.labelIds = remaining
        try message.update(db)
        if toRemove.contains("UNREAD") {
            try recomputeUnreadCount(threadId: ref.threadId, db: db)
        }
    }

    // MARK: - recompute helpers

    private static func recomputeCounts(threadId: String, db: Database) throws {
        guard var thread = try MailThread.fetchOne(db, key: threadId) else { return }
        let messages = try Message
            .filter(Column("thread_id") == threadId)
            .fetchAll(db)
        thread.messageCount = messages.count
        thread.unreadCount = messages.reduce(0) { acc, m in
            acc + (m.labelIds.contains("UNREAD") ? 1 : 0)
        }
        try thread.update(db)
    }

    private static func recomputeUnreadCount(threadId: String, db: Database) throws {
        guard var thread = try MailThread.fetchOne(db, key: threadId) else { return }
        let messages = try Message
            .filter(Column("thread_id") == threadId)
            .fetchAll(db)
        thread.unreadCount = messages.reduce(0) { acc, m in
            acc + (m.labelIds.contains("UNREAD") ? 1 : 0)
        }
        try thread.update(db)
    }
}
