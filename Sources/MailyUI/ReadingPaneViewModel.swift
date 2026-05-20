import Foundation
import MailyCore

@MainActor
public final class ReadingPaneViewModel: ObservableObject {
    @Published public private(set) var thread: MailThread?
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var loadError: String?

    private let accountID: String
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository

    // Handle to the most recent loading task. Cancelled on every new selection
    // so that any continuation queued on the MainActor will bail before it
    // overwrites freshly-published state.
    private var currentLoad: Task<Void, Never>?
    // Monotonic generation token; only the most recent setSelection caller
    // may publish. Defence-in-depth alongside Task cancellation.
    private var currentToken: UInt64 = 0

    public init(
        accountID: String,
        threadRepo: ThreadRepository,
        messageRepo: MessageRepository
    ) {
        self.accountID = accountID
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
    }

    /// Call when the selected thread id changes in the list selection.
    ///
    /// Repos are synchronous and in-memory today, so the fetch runs inline on
    /// the MainActor and state is committed before `setSelection` returns.
    /// We still hold a `Task<Void, Never>?` handle and cancel it on every
    /// entry — that is the contract this VM exposes to callers, and it is
    /// what we will rely on once the fetch becomes truly async.
    public func setSelection(_ threadID: String?) async {
        // Cancel the prior load and bump the generation. After this point any
        // resume from an older task will see `Task.isCancelled` or a stale
        // `currentToken` and silently bail.
        currentLoad?.cancel()
        currentToken &+= 1
        let myToken = currentToken

        guard let threadID else {
            currentLoad = nil
            thread = nil
            messages = []
            loadError = nil
            return
        }

        isLoading = true
        loadError = nil

        // Synchronous fetch. No actor hop, no suspension — by the time this
        // function returns, the @Published state already reflects this call.
        let fetched: Result<(MailThread?, [Message]), Error>
        do {
            let t = try threadRepo.thread(id: threadID)
            if let t {
                let msgs = try messageRepo.messages(threadId: threadID)
                fetched = .success((t, msgs))
            } else {
                fetched = .success((nil, []))
            }
        } catch {
            fetched = .failure(error)
        }

        // Publish inline, guarded by the token. The token guard would
        // normally be unnecessary here (we have not suspended) but keeping it
        // makes the invariant explicit: only the latest token may publish.
        guard self.currentToken == myToken else { return }
        switch fetched {
        case .failure(let error):
            thread = nil
            messages = []
            loadError = error.localizedDescription
        case .success((let t?, let msgs)):
            thread = t
            messages = msgs
            loadError = nil
        case .success((nil, _)):
            thread = nil
            messages = []
            loadError = "Thread not found"
        }
        isLoading = false

        // Clear the handle: nothing remains to cancel. (We do not allocate a
        // dummy Task and await it, because that would yield the MainActor and
        // allow any caller queued behind us to publish over our state.)
        currentLoad = nil
    }
}
