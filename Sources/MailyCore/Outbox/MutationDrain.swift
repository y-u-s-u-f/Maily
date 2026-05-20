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
///   exhausted): increment `attempts`, leave the row in place, and SKIP
///   the row for the rest of this pass while continuing to drain newer
///   rows. The OUTER retry happens on the next `runOnce` invocation;
///   `start()` sleeps between drains.
/// - `AuthenticatedSessionError.needsReauth`: stop the pass immediately
///   without touching the row (no attempts++, no last_error, no rollback).
///   The UI kicks off OAuth via `AuthenticatedSession.needsReauthFlag`;
///   the next outer tick will drain normally.
/// - Once `attempts >= maxAttempts` (default 5), or on any non-retryable
///   HTTP (4xx other than 429), treat it as permanent: record `last_error`,
///   undo the optimistic local change in the same transaction, retain the
///   row (with `last_error` populated) as a terminal "dead" record, and
///   notify the `onPermanentFailure` delegate. Subsequent passes skip dead
///   rows via the `last_error IS NOT NULL` filter.
///
/// Rollback of the optimistic local change happens in the same GRDB
/// transaction as the `last_error`/`attempts` update so the database can
/// never end up with "row marked dead, optimistic change still applied"
/// (or the reverse). For label-shaped kinds (`modifyLabels`, `trash`,
/// `untrash`, `markRead`) the rollback inverts the label set on the local
/// `threads` row. For `send` there is no local optimistic state to roll
/// back yet, so it's a no-op at this layer.
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
        idleInterval: TimeInterval = 5.0
    ) {
        self.db = db
        self.client = client
        self.sleeper = sleeper
        self.maxAttempts = maxAttempts
        self.idleInterval = idleInterval
    }

    public func setOnPermanentFailure(_ handler: @escaping PermanentFailureHandler) {
        self.onPermanentFailure = handler
    }

    // MARK: - drain

    /// Drain every currently pending row.
    ///
    /// A single pass walks the queue oldest-first. A retryable failure on
    /// one row bumps its `attempts` and SKIPS it for the rest of this
    /// pass, then continues with the next-oldest row — one transient
    /// 429/5xx must not stall the entire queue until the next outer tick.
    /// `AuthenticatedSessionError.needsReauth` ends the pass immediately
    /// without touching the row; the next outer tick (after the user
    /// re-auths) will pick it up. Dead rows (`last_error IS NOT NULL`)
    /// are filtered out of the candidate set so they aren't re-attempted.
    public func runOnce() async {
        var skipped: Set<MutationID> = []
        while true {
            // Fetch the oldest still-pending row that isn't already dead
            // and wasn't skipped earlier in this pass.
            let next: PendingMutation?
            do {
                next = try await db.read { [skipped] db in
                    var query = PendingMutation
                        .filter(sql: "last_error IS NULL")
                        .order(Column("created_at").asc, Column("id").asc)
                    if !skipped.isEmpty {
                        query = query.filter(!skipped.contains(Column("id")))
                    }
                    return try query.fetchOne(db)
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
                // Skip for the rest of this pass; the next outer tick
                // will re-pick it up. Re-attempting mid-pass would be a
                // tight loop and defeat the "outer backoff" contract.
                if let id = mutation.id { skipped.insert(id) }
                continue
            case .needsReauth:
                // Token is dead. Stop the pass entirely; the next outer
                // tick (after the UI re-auths) will drain normally.
                return
            }
        }
    }

    private enum Outcome {
        case succeeded
        case retryableFailed
        case permanentlyFailed
        case needsReauth
    }

    private func process(_ mutation: PendingMutation) async -> Outcome {
        guard let id = mutation.id else {
            // A row fetched from GRDB always has an `id`. Reaching this
            // branch indicates a programmer error (e.g. a hand-built
            // `PendingMutation` instance passed to `process`). Fail loudly
            // in debug, fail permanently in production — the safer
            // direction than silently succeeding without making the call.
            assertionFailure("process(_:) called with mutation.id == nil")
            return .permanentlyFailed
        }

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
        // Session-wide conditions where every subsequent call in this
        // pass would also fail. Stop the pass without mutating the row,
        // without rolling back, and without firing the delegate.
        // - `.needsReauth`: refresh token is dead; UI re-runs OAuth.
        // - `.missingRefreshToken`: no refresh token persisted at all —
        //   a config-level issue, not a per-row failure. Bumping
        //   attempts on every row until they all die permanent would
        //   be actively harmful.
        if let sessionError = error as? AuthenticatedSessionError,
           sessionError == .needsReauth || sessionError == .missingRefreshToken {
            return .needsReauth
        }

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

        // Permanent: record error and roll back the optimistic local
        // change in the same transaction. Retain the row as a terminal
        // "dead" record (last_error IS NOT NULL) so subsequent passes
        // skip it; the row stays around for diagnostics and any future
        // user-facing "show failed mutations" surface.
        //
        // A rollback decode failure (the payload was decodable enough to
        // dispatch but somehow not now — shouldn't happen, but the row
        // still has to be marked dead) is surfaced loudly in
        // `last_error` rather than silently swallowed. We MUST NOT bail
        // out of the write because that would leave the row pending and
        // re-dispatch it next pass.
        let baseErrorString = String(describing: error)
        do {
            try await db.write { db in
                let rollbackError: Error?
                do {
                    try Self.rollback(for: mutation, db: db)
                    rollbackError = nil
                } catch {
                    rollbackError = error
                }
                let errorString: String = {
                    guard let rollbackError else { return baseErrorString }
                    return "\(baseErrorString); rollback failed: \(rollbackError)"
                }()
                try db.execute(
                    sql: "UPDATE pending_mutations SET last_error = ?, attempts = ? WHERE id = ?",
                    arguments: [errorString, nextAttempts, id]
                )
            }
        } catch {
            // Rollback or persist failed; bail without notifying so we can
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
        // Decode errors propagate to the caller, which appends them to
        // `last_error` rather than silently dropping the optimistic
        // change. The payload was decodable enough at dispatch time, so
        // a failure here is a real bug worth surfacing.
        switch mutation.kind {
        case .modifyLabels:
            let payload = try MutationPayload.decode(MutationPayload.ModifyLabels.self, from: mutation.payloadJson)
            try applyLabelRollback(
                threadId: payload.threadId,
                undoAdds: payload.addLabelIds,
                undoRemoves: payload.removeLabelIds,
                db: db
            )
        case .trash:
            let payload = try MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson)
            try applyLabelRollback(threadId: payload.threadId, undoAdds: ["TRASH"], undoRemoves: [], db: db)
        case .untrash:
            let payload = try MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson)
            try applyLabelRollback(threadId: payload.threadId, undoAdds: [], undoRemoves: ["TRASH"], db: db)
        case .markRead:
            let payload = try MutationPayload.decode(MutationPayload.ThreadOnly.self, from: mutation.payloadJson)
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
        // Anything outside AuthenticatedSessionError is treated as
        // permanent: the session layer is the contract boundary for what
        // surfaces from a Gmail call, so an unrecognized error type is a
        // programmer error or a corrupted payload — neither benefits from
        // outer retries. `.needsReauth` is handled separately by the
        // caller (it stops the pass rather than counting as retryable or
        // permanent for this row).
        if let sessionError = error as? AuthenticatedSessionError {
            switch sessionError {
            case .http(let status, _):
                return status == 429 || (500...599).contains(status)
            case .invalidResponse:
                // Non-`HTTPURLResponse` from URLSession — a transport /
                // parse glitch. Almost always transient (proxy hiccup,
                // truncated body); same outer-retry path as 5xx/429.
                return true
            case .needsReauth, .missingRefreshToken:
                // Session-wide; handled by the caller before we get
                // here. If for some reason we did, treat as not
                // retryable per-row.
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
