import Foundation
import Combine
// @preconcurrency silences AnyDatabaseCancellable Sendable warning in the nonisolated deinit (GRDB 6 isn't fully Sendable-audited yet).
@preconcurrency import GRDB
import MailyCore

@MainActor
public final class InboxViewModel: ObservableObject {
    @Published public private(set) var threads: [MailThread] = []

    private var cancellable: AnyDatabaseCancellable?

    public init(repository: ThreadRepository, accountID: String) {
        let observation = repository.observeAll(accountId: accountID)
        cancellable = observation.start(
            in: repository.queue,
            scheduling: .async(onQueue: .main),
            // TODO(M4+): surface observation errors via a @Published error state when we wire real persistence.
            onError: { _ in },
            onChange: { [weak self] rows in
                self?.threads = rows
            }
        )
    }

    deinit {
        cancellable?.cancel()
    }
}
