import SwiftUI
import Foundation
import MailyUI
import MailyCore

@main
struct MailyApp: App {
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository
    private let syncEngine: SyncEngine
    private let composeCoordinator: ComposeCoordinator
    private let notifier: MailNotifier
    private let keybindingsLoader: KeybindingsLoader
    @StateObject private var viewModel: InboxViewModel
    @StateObject private var syncStatus: SyncStatusViewModel

    init() {
        // --- OAuth / token-store bootstrap (graceful fallback) -----------------
        // We try to load real credentials from Secrets/oauth.json. If anything
        // goes wrong (missing file, placeholder values, malformed JSON) we log
        // the *error type* (never any secret value) to stderr and fall back to
        // a placeholder config + in-memory token store. SyncEngine will then
        // land in `.error` and StatusBarView (M9-1) surfaces that to the user.
        let oauthConfig: OAuthConfig
        let tokenStore: any TokenStore
        do {
            let secretsURL = try Self.locateSecretsFile()
            oauthConfig = try OAuthConfig.load(from: secretsURL)
            tokenStore = KeychainTokenStore()
        } catch {
            FileHandle.standardError.write(
                Data("Maily: OAuth config unavailable (\(error)). Falling back to placeholder. Sync will fail.\n".utf8)
            )
            oauthConfig = OAuthConfig(
                clientID: "placeholder",
                clientSecret: "placeholder",
                redirectURI: "http://127.0.0.1/oauth/callback"
            )
            tokenStore = InMemoryTokenStore()
        }

        // --- Database + repos --------------------------------------------------
        let db = try! MailyDatabase(location: .inMemory)
        try! db.queue.write { try Account(id: "local", email: "you@maily.app").insert($0) }
        let threadRepo = ThreadRepository(queue: db.queue)
        let messageRepo = MessageRepository(queue: db.queue)
        let accountRepo = AccountRepository(queue: db.queue)
        let mutationRepo = MutationRepository(queue: db.queue)

        // --- Auth session + sync engine ---------------------------------------
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

        // --- Compose coordinator (replaces NoopComposeActions) ----------------
        //
        // `currentReadingMessageID` returns nil for now. Wiring it to the
        // selected message id from ReadingPaneViewModel requires either a
        // shared @MainActor selection coordinator or exposing a published
        // "current message id" on the VM — both deferred to M10 alongside
        // the j/k/e selection coordinator. Reply commands silently no-op
        // until then.
        let coordinator = MainActor.assumeIsolated {
            ComposeCoordinator(
                accountID: "local",
                fromAddress: "you@maily.app",
                messageRepo: messageRepo,
                mutationRepo: mutationRepo,
                currentReadingMessageID: { nil }
            )
        }
        self.composeCoordinator = coordinator

        // --- First-run files + KeybindingsLoader ------------------------------
        do {
            try FirstRun.ensureKeybindingsFile()
        } catch {
            FileHandle.standardError.write(
                Data("Maily: FirstRun.ensureKeybindingsFile failed (\(error)). Continuing without seeded keybindings.\n".utf8)
            )
        }

        // KeybindingsLoader override-application is deferred to M10 — the
        // CommandRegistry doesn't yet expose an "apply overrides" surface.
        // For M9 we just log when the file changes so the watcher path is
        // exercised in production.
        let loader = KeybindingsLoader(
            url: KeybindingsLoader.defaultURL,
            onChange: { overrides in
                FileHandle.standardError.write(
                    Data("Maily: keybindings updated (\(overrides.shortcuts.count) shortcuts)\n".utf8)
                )
            }
        )
        self.keybindingsLoader = loader

        // --- Notifier ---------------------------------------------------------
        // Authorization is requested at launch; per-batch notifications are
        // posted via `notifyNewMail(count:)`. The HistoryWatcher → notifier
        // callback is deferred to M10 (HistoryWatcher needs a new param).
        let notifier = MailNotifier()
        self.notifier = notifier

        // --- Repos + view models ---------------------------------------------
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        _viewModel = StateObject(wrappedValue: InboxViewModel(repository: threadRepo, accountID: "local"))
        _syncStatus = StateObject(wrappedValue: SyncStatusViewModel(engine: engine))

        // --- Launch tasks -----------------------------------------------------
        Task.detached { await engine.startSync() }
        Task.detached { await notifier.start() }
        Task.detached { await loader.startWatching() }
    }

    var body: some Scene {
        MailWindow(
            viewModel: viewModel,
            syncStatus: syncStatus,
            accountID: "local",
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            composeActions: composeCoordinator
        )
    }

    // MARK: - Secrets location

    private enum SecretsLocateError: Error, CustomStringConvertible {
        case notFound
        var description: String {
            switch self {
            case .notFound: return "Secrets/oauth.json not found in bundle or any parent of source tree"
            }
        }
    }

    /// Resolve `Secrets/oauth.json` in priority order:
    /// 1. App bundle (production):
    ///    `<bundle>/Contents/Resources/Secrets/oauth.json`
    /// 2. Dev: walk parents of `#filePath` looking for `Secrets/oauth.json`.
    ///    For Maily, the file lives at `~/Maily/Secrets/oauth.json` (per
    ///    user memory `feedback_maily_secrets.md`).
    ///
    /// Never echoes the file's contents or any of its values.
    private static func locateSecretsFile(filePath: String = #filePath) throws -> URL {
        let fm = FileManager.default

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Secrets/oauth.json")
        if fm.fileExists(atPath: bundled.path) {
            return bundled
        }

        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        // Walk up; bound the search so we never wander the whole filesystem.
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Secrets/oauth.json")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break } // hit filesystem root
            dir = parent
        }

        throw SecretsLocateError.notFound
    }
}
