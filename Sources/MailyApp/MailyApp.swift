import SwiftUI
import MailyUI
import MailyCore

@main
struct MailyApp: App {
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository
    @StateObject private var viewModel: InboxViewModel

    init() {
        let db = try! MailyDatabase(location: .inMemory)
        try! db.queue.write { try Account(id: "local", email: "you@maily.app").insert($0) }
        let threadRepo = ThreadRepository(queue: db.queue)
        let messageRepo = MessageRepository(queue: db.queue)
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        _viewModel = StateObject(wrappedValue: InboxViewModel(repository: threadRepo, accountID: "local"))
    }

    var body: some Scene {
        MailWindow(
            viewModel: viewModel,
            accountID: "local",
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
    }
}
