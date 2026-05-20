import Foundation
import GRDB
import OSLog

public actor SyncEngine {

    public enum Phase: Sendable, Equatable {
        case idle
        case enumerating
        case fetchingMetadata(processed: Int)
        case fetchingBodies(processed: Int)
        case watching
        case draining
        case error(message: String)
    }

    private static let log = Logger(subsystem: "com.maily.core", category: "SyncEngine")

    private let client: GmailClient
    private let db: any DatabaseWriter
    private let accountRepo: AccountRepository
    private let accountID: String
    private let labels: [String]
    private let bodyLimit: Int

    private let historyIdProvider: @Sendable () async throws -> String?
    private let enumerateClosure: @Sendable () async throws -> [MessageRef]
    private let syncMetadataClosure: @Sendable ([MessageRef], @escaping @Sendable (Int) -> Void) async throws -> Void
    private let fetchBodiesClosure: @Sendable (@escaping @Sendable (Int) -> Void) async throws -> Void
    private let startWatcherOverride: (@Sendable () async -> Void)?
    private let stopWatcherOverride: (@Sendable () async -> Void)?
    private let startDrainOverride: (@Sendable () async -> Void)?
    private let stopDrainOverride: (@Sendable () async -> Void)?

    private var currentPhase: Phase = .idle
    private var continuation: AsyncStream<Phase>.Continuation?
    private var runTask: Task<Void, Never>?

    private var defaultWatcher: HistoryWatcher?
    private var defaultDrain: MutationDrain?

    public init(
        client: GmailClient,
        db: any DatabaseWriter,
        accountRepo: AccountRepository,
        accountID: String,
        labels: [String] = ["INBOX"],
        bodyLimit: Int = 200,
        historyIdProvider: (@Sendable () async throws -> String?)? = nil,
        enumerate: (@Sendable () async throws -> [MessageRef])? = nil,
        syncMetadata: (@Sendable ([MessageRef]) async throws -> Void)? = nil,
        fetchBodies: (@Sendable () async throws -> Void)? = nil,
        startWatcher: (@Sendable () async -> Void)? = nil,
        stopWatcher: (@Sendable () async -> Void)? = nil,
        startDrain: (@Sendable () async -> Void)? = nil,
        stopDrain: (@Sendable () async -> Void)? = nil
    ) {
        self.client = client
        self.db = db
        self.accountRepo = accountRepo
        self.accountID = accountID
        self.labels = labels
        self.bodyLimit = bodyLimit

        let capturedClient = client
        let capturedRepo = accountRepo
        let capturedAccountID = accountID
        let capturedLabels = labels
        let capturedDB = db
        let capturedBodyLimit = bodyLimit

        self.historyIdProvider = historyIdProvider ?? {
            try await capturedClient.getProfile().historyId
        }

        self.enumerateClosure = enumerate ?? {
            let enumerator = InitialMessageEnumerator(
                client: capturedClient,
                accountRepo: capturedRepo,
                accountID: capturedAccountID,
                labels: capturedLabels
            )
            return try await enumerator.enumerate()
        }

        if let syncMetadata {
            self.syncMetadataClosure = { refs, _ in try await syncMetadata(refs) }
        } else {
            self.syncMetadataClosure = { refs, onChunk in
                let syncer = MetadataBatchSyncer(
                    client: capturedClient,
                    db: capturedDB,
                    accountID: capturedAccountID,
                    onChunk: onChunk
                )
                try await syncer.sync(refs)
            }
        }

        if let fetchBodies {
            self.fetchBodiesClosure = { _ in try await fetchBodies() }
        } else {
            self.fetchBodiesClosure = { onProgress in
                let fetcher = EagerBodyFetcher(
                    client: capturedClient,
                    db: capturedDB,
                    accountID: capturedAccountID,
                    limit: capturedBodyLimit,
                    onProgress: onProgress
                )
                try await fetcher.fetchTopInbox()
            }
        }

        self.startWatcherOverride = startWatcher
        self.stopWatcherOverride = stopWatcher
        self.startDrainOverride = startDrain
        self.stopDrainOverride = stopDrain
    }

    public func phaseStream() async -> AsyncStream<Phase> {
        let (stream, continuation) = AsyncStream<Phase>.makeStream()
        self.continuation = continuation
        continuation.yield(currentPhase)
        return stream
    }

    /// Re-sync entrypoint fired when the wired HistoryWatcher reports the
    /// stored historyId has expired (404). Public so tests can drive this
    /// from an injected `startWatcher` to verify the re-sync path.
    public func handleHistoryExpired() async {
        await runStopWatcher()
        try? accountRepo.updateHistoryId(nil, for: accountID)
        runTask?.cancel()
        runTask = nil
        await startSync()
    }

    public func startSync() async {
        if let task = runTask, !task.isCancelled {
            return
        }
        // Detached so a re-entrant `handleHistoryExpired()` triggered from
        // within the current pipeline's `startWatcher` doesn't propagate
        // the just-cancelled parent task's cancellation flag into the
        // freshly-spawned re-sync task.
        let task = Task<Void, Never>.detached { [weak self] in
            await self?.runPipeline()
        }
        runTask = task
    }

    public func stop() async {
        let task = runTask
        runTask = nil
        task?.cancel()
        await runStopWatcher()
        await runStopDrain()
        setPhase(.idle)
    }

    private func setPhase(_ phase: Phase) {
        currentPhase = phase
        continuation?.yield(phase)
    }

    private func bumpMetadataProgress(by n: Int) {
        if case let .fetchingMetadata(processed) = currentPhase {
            setPhase(.fetchingMetadata(processed: processed + n))
        }
    }

    private func bumpBodyProgress(by n: Int) {
        if case let .fetchingBodies(processed) = currentPhase {
            setPhase(.fetchingBodies(processed: processed + n))
        }
    }

    private func runStartWatcher() async {
        if let override = startWatcherOverride {
            await override()
            return
        }
        let watcher = HistoryWatcher(
            client: client,
            db: db,
            accountRepo: accountRepo,
            accountID: accountID,
            onHistoryExpired: { [weak self] in
                Task { await self?.handleHistoryExpired() }
            }
        )
        defaultWatcher = watcher
        await watcher.start()
    }

    private func runStopWatcher() async {
        if let override = stopWatcherOverride {
            await override()
            return
        }
        await defaultWatcher?.stop()
        defaultWatcher = nil
    }

    private func runStartDrain() async {
        if let override = startDrainOverride {
            await override()
            return
        }
        let drain = MutationDrain(
            db: db,
            client: client,
            sleeper: { interval in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        )
        defaultDrain = drain
        await drain.start()
    }

    private func runStopDrain() async {
        if let override = stopDrainOverride {
            await override()
            return
        }
        await defaultDrain?.stop()
        defaultDrain = nil
    }

    private func runPipeline() async {
        let account: Account?
        do {
            account = try accountRepo.allAccounts().first { $0.id == accountID }
        } catch {
            setPhase(.error(message: String(describing: error)))
            return
        }

        let hasBaseline = (account?.historyId != nil)

        if !hasBaseline {
            setPhase(.enumerating)
            let refs: [MessageRef]
            do {
                refs = try await enumerateClosure()
            } catch {
                setPhase(.error(message: String(describing: error)))
                return
            }
            if Task.isCancelled { return }

            setPhase(.fetchingMetadata(processed: 0))
            do {
                try await syncMetadataClosure(refs, { [weak self] n in
                    Task { await self?.bumpMetadataProgress(by: n) }
                })
            } catch {
                setPhase(.error(message: String(describing: error)))
                return
            }
            if Task.isCancelled { return }

            setPhase(.fetchingBodies(processed: 0))
            do {
                try await fetchBodiesClosure({ [weak self] n in
                    Task { await self?.bumpBodyProgress(by: n) }
                })
            } catch {
                Self.log.warning("eager body fetch failed: \(String(describing: error), privacy: .public); proceeding to history watcher")
            }
            if Task.isCancelled { return }

            let newHistoryId: String?
            do {
                newHistoryId = try await historyIdProvider()
            } catch {
                setPhase(.error(message: String(describing: error)))
                return
            }
            if let newHistoryId {
                do {
                    try accountRepo.updateHistoryId(newHistoryId, for: accountID)
                } catch {
                    setPhase(.error(message: String(describing: error)))
                    return
                }
            }
            if Task.isCancelled { return }
        }

        setPhase(.watching)
        await runStartWatcher()
        if Task.isCancelled { return }

        setPhase(.draining)
        await runStartDrain()
    }
}
