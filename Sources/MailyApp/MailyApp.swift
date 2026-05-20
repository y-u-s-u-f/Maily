import SwiftUI
import Foundation
import MailyUI
import MailyCore

@main
enum MailyMain {
    static func main() {
        switch HelperMode.parse(CommandLine.arguments) {
        case .syncOnly:
            runHelper()
            exit(0)
        case .normal:
            MailyAppScene.main()
        }
    }

    /// Headless sync path used by the LaunchAgent. In this v1 there is no
    /// persisted OAuth-bound account, so `startSync()` will fail at the
    /// token-refresh step and land the engine in `.error` — same as the
    /// normal app on first launch. The point of this entry point right now
    /// is wiring: `@main` dispatches here, no SwiftUI Scene is created, and
    /// `exit(0)` runs after a finite delay. A persisted account replaces
    /// the placeholder OAuth plumbing in a later milestone.
    private static func runHelper() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let db = try! MailyDatabase(location: .inMemory)
            try! await db.queue.write { try Account(id: "local", email: "you@maily.app").insert($0) }
            let accountRepo = AccountRepository(queue: db.queue)
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
            await engine.startSync()
            // Give the pipeline a moment to settle into `.watching` or
            // `.error`, then stop. Real OAuth-bound builds will replace
            // this with a deterministic single-pass drain.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await engine.stop()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

struct MailyAppScene: App {
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository
    private let syncEngine: SyncEngine
    private let notifier: MailNotifier
    @StateObject private var viewModel: InboxViewModel

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

        let notifier = MailNotifier(messageRepo: messageRepo, accountID: "local")
        self.notifier = notifier

        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        _viewModel = StateObject(wrappedValue: InboxViewModel(repository: threadRepo, accountID: "local"))

        Task.detached { await engine.startSync() }
        // engine + notifier kick off in parallel; both are best-effort at launch.
        // MailNotifier.start() is @MainActor-isolated, so the `await` from
        // this nonisolated detached task hops to the main actor automatically.
        // The explicit `@MainActor in` closure annotation hits a Swift 6.3
        // region-based isolation checker bug when capturing a @MainActor
        // reference from a @MainActor init, so it is omitted here.
        Task.detached { await notifier.start() }
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
