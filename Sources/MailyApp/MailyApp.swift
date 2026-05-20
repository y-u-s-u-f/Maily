import SwiftUI
import MailyUI
import MailyCore

@main
struct MailyApp: App {
    @StateObject private var viewModel: InboxViewModel = {
        let db = try! MailyDatabase(location: .inMemory)
        try! db.queue.write { try Account(id: "local", email: "you@maily.app").insert($0) }
        let repository = ThreadRepository(queue: db.queue)
        return InboxViewModel(repository: repository, accountID: "local")
    }()

    var body: some Scene {
        MailWindow(viewModel: viewModel)
    }
}
