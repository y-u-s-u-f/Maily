import SwiftUI
import Foundation
import MailyUI
import MailyCore

@main
struct MailyApp: App {
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository
    private let syncEngine: SyncEngine
    @StateObject private var viewModel: InboxViewModel
    @StateObject private var syncStatus: SyncStatusViewModel

    init() {
        let db = try! MailyDatabase(location: .inMemory)
        try! db.queue.write { try Account(id: "local", email: "you@maily.app").insert($0) }
        let threadRepo = ThreadRepository(queue: db.queue)
        let messageRepo = MessageRepository(queue: db.queue)
        let accountRepo = AccountRepository(queue: db.queue)

        // Minimum wiring so the engine exists in v1. There is no OAuth-bound
        // account persisted yet — startSync() will fail at the historyId
        // baseline step (missing refresh token) and land in `.error`, which
        // is correct behavior until OAuth-bound accounts ship.
        // TODO: replace placeholder session/token plumbing once OAuth-bound
        // accounts are persisted at sign-in.
        let tokenStore = InMemoryTokenStore()
        let oauthConfig = OAuthConfig(
            clientID: "placeholder",
            clientSecret: "placeholder",
            redirectURI: "http://127.0.0.1/oauth/callback"
        )
        let tokenEndpoint = TokenEndpoint(config: oauthConfig)
        let session = AuthenticatedSession(
            account: "you@maily.app",
            tokenStore: tokenStore,
            tokenEndpoint: tokenEndpoint
        )
        let client = GmailClient(session: session)
        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: accountRepo,
            accountID: "local"
        )
        self.syncEngine = engine

        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        _viewModel = StateObject(wrappedValue: InboxViewModel(repository: threadRepo, accountID: "local"))
        _syncStatus = StateObject(wrappedValue: SyncStatusViewModel(engine: engine))

        Task.detached { await engine.startSync() }
    }

    var body: some Scene {
        MailWindow(
            viewModel: viewModel,
            syncStatus: syncStatus,
            accountID: "local",
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
    }
}
