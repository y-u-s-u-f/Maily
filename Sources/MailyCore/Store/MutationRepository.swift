import Foundation
import GRDB

/// Outbox-shaped repository over `pending_mutations`.
///
/// `MutationDrain` reads/writes the table directly because it juggles
/// dispatch, retry, and rollback in one transaction; this repository is
/// the call-site face — UI code enqueues a row here and the drain takes
/// it from there.
///
/// Made a protocol so view-model tests can substitute a throwing fake
/// without spinning up a closed `DatabaseQueue`. `MutationRepository`
/// (the concrete type) is the only production conformance.
public protocol MutationEnqueuing: Sendable {
    /// Insert `mutation` and return the assigned row id. The id is also
    /// written back into the passed-in `mutation` by GRDB's
    /// `didInsert(_:)` hook, but callers usually don't need it.
    func enqueue(_ mutation: PendingMutation) throws -> Int64
}

public struct MutationRepository: MutationEnqueuing {
    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func enqueue(_ mutation: PendingMutation) throws -> Int64 {
        try queue.write { db in
            var m = mutation
            try m.insert(db)
            // `didInsert` populates `m.id`; force-unwrap is safe because
            // GRDB always assigns the rowID on a successful insert.
            return m.id!
        }
    }
}
