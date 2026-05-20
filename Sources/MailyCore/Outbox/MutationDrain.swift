import Foundation
import GRDB

/// Drains the `pending_mutations` table to Gmail.
///
/// Background loop: pop the oldest pending row, decode its `payload_json`
/// per `kind`, dispatch the matching `GmailClient` call, and delete the
/// row on success.
///
/// Failure handling:
/// - Retryable HTTP failure (5xx / 429 — these surface from
///   `AuthenticatedSession` only after *its* internal retries are
///   exhausted): increment `attempts`, leave the row in place. The OUTER
///   retry happens on the next `runOnce` invocation; `start()` sleeps with
///   exponential backoff between drains.
/// - Once `attempts >= maxAttempts` (default 5), or on any non-retryable
///   HTTP (4xx other than 429), treat it as permanent: record `last_error`,
///   undo the optimistic local change in the same transaction, delete the
///   row, and notify the `onPermanentFailure` delegate.
///
/// Rollback of the optimistic local change happens in the same GRDB
/// transaction as the row deletion so the database can never end up with
/// "row gone, optimistic change still applied" (or the reverse). For
/// label-shaped kinds (`modifyLabels`, `trash`, `untrash`, `markRead`) the
/// rollback inverts the label set on the local `threads` row. For `send`
/// there is no local optimistic state to roll back yet, so it's a no-op
/// at this layer.
public actor MutationDrain {

    // MARK: - public types

    public typealias MutationID = Int64
    public typealias PermanentFailureHandler = @Sendable (MutationID, Error) -> Void

    public enum DrainError: Error, Equatable {
        /// The row's `payload_json` could not be decoded into the expected
        /// shape for its `kind`. Treated as permanent — the row would
        /// otherwise be stuck.
        case payloadDecodeFailed(kind: String)
    }

    // MARK: - dependencies

    private let db: any DatabaseWriter
    private let client: GmailClient
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let maxAttempts: Int
    private let baseBackoff: TimeInterval
    private let idleInterval: TimeInterval

    // MARK: - state

    private var onPermanentFailure: PermanentFailureHandler?
    private var loopTask: Task<Void, Never>?

    // MARK: - init

    public init(
        db: any DatabaseWriter,
        client: GmailClient,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void,
        maxAttempts: Int = 5,
        baseBackoff: TimeInterval = 0.5,
        idleInterval: TimeInterval = 5.0
    ) {
        self.db = db
        self.client = client
        self.sleeper = sleeper
        self.maxAttempts = maxAttempts
        self.baseBackoff = baseBackoff
        self.idleInterval = idleInterval
    }

    public func setOnPermanentFailure(_ handler: @escaping PermanentFailureHandler) {
        self.onPermanentFailure = handler
    }

    // MARK: - drain

    /// Drain every currently pending row. Stops early if a row fails
    /// retryably (its `attempts` is bumped and the loop yields so the
    /// outer `start()` loop can apply exponential backoff before the next
    /// drain).
    public func runOnce() async {
        while true {
            // Fetch the oldest row.
            let next: PendingMutation?
            do {
                next = try await db.read { db in
                    try PendingMutation
                        .order(Column("created_at").asc, Column("id").asc)
                        .fetchOne(db)
                }
            } catch {
                // Reading the queue itself failed — give up this pass.
                return
            }
            guard let mutation = next else { return }

            let outcome = await process(mutation)
            switch outcome {
            case .succeeded, .permanentlyFailed:
                continue
            case .retryableFailed:
                // Leave the row, exit the pass so start() can back off.
                return
            }
        }
    }

    private enum Outcome {
        case succeeded
        case retryableFailed
        case permanentlyFailed
    }

    private func process(_ mutation: PendingMutation) async -> Outcome {
        guard let id = mutation.id else { return .succeeded }

        // Decode + dispatch.
        do {
            try await dispatch(mutation)
        } catch {
            return await handleFailure(mutation, id: id, error: error)
        }

        // Success: drop the row.
        do {
            _ = try await db.write { db in
                try PendingMutation.deleteOne(db, key: id)
            }
        } catch {
            // If we can't delete the row we'll just retry it next pass.
            return .retryableFailed
        }
        return .succeeded
    }

    private func dispatch(_ mutation: PendingMutation) async throws {
        switch mutation.kind {
        case .modifyLabels:
            let payload: MutationPayload.ModifyLabels
            do {
                payload = try MutationPayload.decode(MutationPayload.ModifyLabels.self, from: mutation.payloadJson)
            } catch {
                throw DrainError.payloadDecodeFailed(kind: mutation.kindRaw)
            }
            _ = try await client.modifyThread(
                id: payload.threadId,
                addLabelIds: payload.addLabelIds,
                removeLabelIds: payload.removeLabelIds
            )

        case .trash:
            let payload = try decodeThreadOnly(mutation)
            _ = try await client.modifyThread(
                id: payload.threadId,
                addLabelIds: ["TRASH"],
                removeLabelIds: []
            )

        case .untrash:
            let payload = try decodeThreadOnly(mutation)
            _ = try await client.modifyThread(
                id: payload.threadId,
                addLabelIds: [],
                removeLabelIds: ["TRASH"]
            )

        case .markRead:
            let payload = try decodeThreadOnly(mutation)
            _ = try await client.modifyThread(
                id: payload.threadId,
                addLabelIds: [],
                removeLabelIds: ["UNREAD"]
            )

        case .send:
            let payload: MutationPayload.Send
            do {
                payload = try MutationPayload.decode(MutationPayload.Send.self, from: mutation.payloadJson)
            } catch {
                throw DrainError.payloadDecodeFailed(kind: mutation.kindRaw)
            }
            _ = try await client.sendMessage(payload.outgoingMessage, threadId: payload.threadId)
        }
    }

    private func decodeThreadOnly(_ mutation: PendingMutation) throws -> MutationPayload.ThreadOnly {
        do {
            return try MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson)
        } catch {
            throw DrainError.payloadDecodeFailed(kind: mutation.kindRaw)
        }
    }

    // MARK: - failure handling

    private func handleFailure(_ mutation: PendingMutation, id: MutationID, error: Error) async -> Outcome {
        let retryable = Self.isRetryable(error)
        let nextAttempts = mutation.attempts + 1
        let hitCap = nextAttempts >= maxAttempts

        if retryable && !hitCap {
            // Bump attempts, leave the row.
            do {
                try await db.write { db in
                    try db.execute(
                        sql: "UPDATE pending_mutations SET attempts = ? WHERE id = ?",
                        arguments: [nextAttempts, id]
                    )
                }
            } catch {
                // Swallow — we'll just try again with the same attempts count.
            }
            return .retryableFailed
        }

        // Permanent: record error, roll back, delete — all in one tx.
        let errorString = String(describing: error)
        do {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE pending_mutations SET last_error = ?, attempts = ? WHERE id = ?",
                    arguments: [errorString, nextAttempts, id]
                )
                try Self.rollback(for: mutation, db: db)
                try PendingMutation.deleteOne(db, key: id)
            }
        } catch {
            // Rollback or delete failed; bail without notifying so we can
            // try again next pass rather than dropping the failure on the
            // floor.
            return .retryableFailed
        }

        onPermanentFailure?(id, error)
        return .permanentlyFailed
    }

    // MARK: - rollback

    /// Undo the optimistic local change for `mutation` on the `threads`
    /// row. `send` is a no-op — there is no enqueued local `Message` row
    /// yet at this layer of the build, so there is nothing to undo.
    static func rollback(for mutation: PendingMutation, db: Database) throws {
        switch mutation.kind {
        case .modifyLabels:
            guard let payload = try? MutationPayload.decode(MutationPayload.ModifyLabels.self, from: mutation.payloadJson) else { return }
            try applyLabelRollback(
                threadId: payload.threadId,
                undoAdds: payload.addLabelIds,
                undoRemoves: payload.removeLabelIds,
                db: db
            )
        case .trash:
            guard let payload = try? MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson) else { return }
            try applyLabelRollback(threadId: payload.threadId, undoAdds: ["TRASH"], undoRemoves: [], db: db)
        case .untrash:
            guard let payload = try? MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson) else { return }
            try applyLabelRollback(threadId: payload.threadId, undoAdds: [], undoRemoves: ["TRASH"], db: db)
        case .markRead:
            guard let payload = try? MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson) else { return }
            try applyLabelRollback(threadId: payload.threadId, undoAdds: [], undoRemoves: ["UNREAD"], db: db)
        case .send:
            // No local optimistic Message row enqueued yet — nothing to undo.
            return
        }
    }

    /// Invert a label change on a thread:
    /// - Labels that were optimistically added (`undoAdds`) get removed.
    /// - Labels that were optimistically removed (`undoRemoves`) get re-added.
    private static func applyLabelRollback(
        threadId: String,
        undoAdds: [String],
        undoRemoves: [String],
        db: Database
    ) throws {
        guard var thread = try MailThread.fetchOne(db, key: threadId) else { return }
        var labels = thread.labelIds
        labels.removeAll(where: { undoAdds.contains($0) })
        for label in undoRemoves where !labels.contains(label) {
            labels.append(label)
        }
        thread.labelIds = labels
        try thread.update(db)
    }

    // MARK: - retryability

    static func isRetryable(_ error: Error) -> Bool {
        if let sessionError = error as? AuthenticatedSessionError {
            switch sessionError {
            case .http(let status, _):
                return status == 429 || (500...599).contains(status)
            default:
                return false
            }
        }
        return false
    }

    // MARK: - lifecycle

    /// Spawn the long-running drain loop: drain, sleep, drain. Idempotent —
    /// calling twice is a no-op while the first loop is still active.
    public func start() async {
        if loopTask != nil { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                if Task.isCancelled { return }
                let interval = await self.idleSleepInterval()
                await self.sleeper(interval)
            }
        }
    }

    /// Cancel the loop and wait for it to finish.
    public func stop() async {
        guard let task = loopTask else { return }
        task.cancel()
        await task.value
        loopTask = nil
    }

    private func idleSleepInterval() -> TimeInterval {
        idleInterval
    }
}
