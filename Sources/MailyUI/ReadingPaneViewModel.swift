import Foundation
import MailyCore

@MainActor
public final class ReadingPaneViewModel: ObservableObject {
    // TODO(M5+): observe via ValueObservation instead of one-shot fetch (cf. InboxViewModel) — current impl won't reflect mid-read DB updates.

    @Published public private(set) var thread: MailThread?
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var loadError: String?

    // Reserved for M5+ account scoping; intentionally unused today.
    private let accountID: String
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository

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
    // Synchronous fetch on @MainActor — latest call wins by serialization. TODO(M5+): reintroduce cancellation guards when repo calls suspend.
    public func setSelection(_ threadID: String?) async {
        guard let threadID else {
            thread = nil
            messages = []
            loadError = nil
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil

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
    }
}
