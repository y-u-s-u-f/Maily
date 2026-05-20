import XCTest
import GRDB
@testable import MailyCore

final class SyncEngineTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - fixture

    private func makeFixture(baseline: String? = nil) throws -> (MailyDatabase, AccountRepository, GmailClient) {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write {
            try Account(id: "acct", email: "u@x", historyId: baseline).insert($0)
        }
        let repo = AccountRepository(queue: db.queue)
        let client = GmailClientTests.makeClient()
        return (db, repo, client)
    }

    /// Drain a phase stream until the predicate matches or timeout elapses.
    /// Returns all collected phases.
    private func collectPhases(
        _ stream: AsyncStream<SyncEngine.Phase>,
        until predicate: @escaping @Sendable (SyncEngine.Phase) async -> Bool,
        timeoutNS: UInt64 = 5_000_000_000
    ) async throws -> [SyncEngine.Phase] {
        let collector = PhaseCollector()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await phase in stream {
                    await collector.append(phase)
                    if await predicate(phase) { return }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNS)
                throw TimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
        return await collector.phases
    }

    // MARK: - test 1: first-run full pipeline

    func testFirstRunFlowsThroughFullPipeline() async throws {
        let (db, repo, client) = try makeFixture(baseline: nil)
        let refs = [MessageRef(id: "m1", threadId: "t1")]

        let metadataCalls = CounterBox()
        let bodyCalls = CounterBox()
        let watcherStarts = CounterBox()
        let drainStarts = CounterBox()

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { "h-new" },
            enumerate: { refs },
            syncMetadata: { _ in await metadataCalls.incr() },
            fetchBodies: { await bodyCalls.incr() },
            startWatcher: { await watcherStarts.incr() },
            stopWatcher: { },
            startDrain: { await drainStarts.incr() },
            stopDrain: { }
        )

        let stream = await engine.phaseStream()
        await engine.startSync()
        let phases = try await collectPhases(stream, until: { phase in
            if case .draining = phase { return true }
            return false
        })

        XCTAssertTrue(phases.contains(.enumerating))
        XCTAssertTrue(phases.contains(.fetchingMetadata(processed: 0)))
        XCTAssertTrue(phases.contains(.fetchingBodies(processed: 0)))
        XCTAssertTrue(phases.contains(.watching))
        XCTAssertTrue(phases.contains(.draining))

        // ordering: each must appear after the previous one's first occurrence.
        let firstIndex: (SyncEngine.Phase) -> Int? = { target in
            phases.firstIndex(where: { $0 == target })
        }
        let iEnum = firstIndex(.enumerating)
        let iMeta = firstIndex(.fetchingMetadata(processed: 0))
        let iBodies = firstIndex(.fetchingBodies(processed: 0))
        let iWatch = firstIndex(.watching)
        let iDrain = firstIndex(.draining)
        XCTAssertNotNil(iEnum); XCTAssertNotNil(iMeta); XCTAssertNotNil(iBodies); XCTAssertNotNil(iWatch); XCTAssertNotNil(iDrain)
        XCTAssertLessThan(iEnum!, iMeta!)
        XCTAssertLessThan(iMeta!, iBodies!)
        XCTAssertLessThan(iBodies!, iWatch!)
        XCTAssertLessThan(iWatch!, iDrain!)

        do { let v = await metadataCalls.read(); XCTAssertEqual(v, 1) }
        do { let v = await bodyCalls.read(); XCTAssertEqual(v, 1) }
        do { let v = await watcherStarts.read(); XCTAssertEqual(v, 1) }
        do { let v = await drainStarts.read(); XCTAssertEqual(v, 1) }
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "h-new")

        await engine.stop()
    }

    // MARK: - test 2: subsequent run skips enumerate/metadata/bodies

    func testSubsequentRunSkipsEnumerationAndMetadata() async throws {
        let (db, repo, client) = try makeFixture(baseline: "h-existing")

        let enumCalls = CounterBox()
        let metaCalls = CounterBox()
        let bodyCalls = CounterBox()
        let watcherStarts = CounterBox()
        let drainStarts = CounterBox()

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { XCTFail("historyIdProvider should not be called"); return nil },
            enumerate: { await enumCalls.incr(); return [] },
            syncMetadata: { _ in await metaCalls.incr() },
            fetchBodies: { await bodyCalls.incr() },
            startWatcher: { await watcherStarts.incr() },
            stopWatcher: { },
            startDrain: { await drainStarts.incr() },
            stopDrain: { }
        )

        let stream = await engine.phaseStream()
        await engine.startSync()
        let phases = try await collectPhases(stream, until: { phase in
            if case .draining = phase { return true }
            return false
        })

        do { let v = await enumCalls.read(); XCTAssertEqual(v, 0) }
        do { let v = await metaCalls.read(); XCTAssertEqual(v, 0) }
        do { let v = await bodyCalls.read(); XCTAssertEqual(v, 0) }
        do { let v = await watcherStarts.read(); XCTAssertEqual(v, 1) }
        do { let v = await drainStarts.read(); XCTAssertEqual(v, 1) }
        XCTAssertFalse(phases.contains(.enumerating))
        XCTAssertFalse(phases.contains(.fetchingMetadata(processed: 0)))
        XCTAssertFalse(phases.contains(.fetchingBodies(processed: 0)))
        XCTAssertTrue(phases.contains(.watching))
        XCTAssertTrue(phases.contains(.draining))

        await engine.stop()
    }

    // MARK: - test 3: stop() cancels watchers and returns to idle

    func testStopCancelsWatcherAndDrainAndReturnsToIdle() async throws {
        let (db, repo, client) = try makeFixture(baseline: "h")
        let stopWatcherCalls = CounterBox()
        let stopDrainCalls = CounterBox()

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { "h" },
            enumerate: { [] },
            syncMetadata: { _ in },
            fetchBodies: { },
            startWatcher: { },
            stopWatcher: { await stopWatcherCalls.incr() },
            startDrain: { },
            stopDrain: { await stopDrainCalls.incr() }
        )

        let stream = await engine.phaseStream()
        await engine.startSync()
        _ = try await collectPhases(stream, until: { phase in
            if case .draining = phase { return true }
            return false
        })

        await engine.stop()

        do { let v = await stopWatcherCalls.read(); XCTAssertEqual(v, 1) }
        do { let v = await stopDrainCalls.read(); XCTAssertEqual(v, 1) }

        let finalStream = await engine.phaseStream()
        var first: SyncEngine.Phase?
        for await p in finalStream { first = p; break }
        XCTAssertEqual(first, .idle)
    }

    // MARK: - test 4: concurrent startSync calls are deduped

    func testConcurrentStartSyncOnlyRunsOnce() async throws {
        let (db, repo, client) = try makeFixture(baseline: "h")
        let watcherStarts = CounterBox()
        let releaseGate = ReleaseGate()

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { "h" },
            enumerate: { [] },
            syncMetadata: { _ in },
            fetchBodies: { },
            startWatcher: {
                await watcherStarts.incr()
                await releaseGate.wait()
            },
            stopWatcher: { await releaseGate.release() },
            startDrain: { },
            stopDrain: { }
        )

        async let first: Void = engine.startSync()
        async let second: Void = engine.startSync()
        _ = await (first, second)

        // Give the in-flight pipeline a beat to reach startWatcher.
        try await Task.sleep(nanoseconds: 100_000_000)
        do { let v = await watcherStarts.read(); XCTAssertEqual(v, 1) }

        await engine.stop()
    }

    // MARK: - test 5: metadata failure surfaces as .error

    func testMetadataFailureSurfacesAsErrorAndSkipsWatcherDrain() async throws {
        let (db, repo, client) = try makeFixture(baseline: nil)
        let watcherStarts = CounterBox()
        let drainStarts = CounterBox()

        struct Boom: Error {}

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { XCTFail("historyIdProvider unreachable"); return nil },
            enumerate: { [MessageRef(id: "m1", threadId: "t1")] },
            syncMetadata: { _ in throw Boom() },
            fetchBodies: { XCTFail("fetchBodies unreachable") },
            startWatcher: { await watcherStarts.incr() },
            stopWatcher: { },
            startDrain: { await drainStarts.incr() },
            stopDrain: { }
        )

        let stream = await engine.phaseStream()
        await engine.startSync()
        let phases = try await collectPhases(stream, until: { phase in
            if case .error = phase { return true }
            return false
        })

        do { let v = await watcherStarts.read(); XCTAssertEqual(v, 0) }
        do { let v = await drainStarts.read(); XCTAssertEqual(v, 0) }
        XCTAssertEqual(try repo.allAccounts().first?.historyId, nil)
        let last = phases.last
        if case .error = last { } else { XCTFail("expected terminal .error, got \(String(describing: last))") }
    }

    // MARK: - test 6: body-fetch failure is non-fatal

    func testBodyFetchFailureProceedsToWatcherAndDrain() async throws {
        let (db, repo, client) = try makeFixture(baseline: nil)
        let watcherStarts = CounterBox()
        let drainStarts = CounterBox()

        struct Boom: Error {}

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { "h-new" },
            enumerate: { [] },
            syncMetadata: { _ in },
            fetchBodies: { throw Boom() },
            startWatcher: { await watcherStarts.incr() },
            stopWatcher: { },
            startDrain: { await drainStarts.incr() },
            stopDrain: { }
        )

        let stream = await engine.phaseStream()
        await engine.startSync()
        let phases = try await collectPhases(stream, until: { phase in
            if case .draining = phase { return true }
            return false
        })

        do { let v = await watcherStarts.read(); XCTAssertEqual(v, 1) }
        do { let v = await drainStarts.read(); XCTAssertEqual(v, 1) }
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "h-new")
        XCTAssertTrue(phases.contains(.watching))
        XCTAssertTrue(phases.contains(.draining))
        for p in phases {
            if case .error = p {
                XCTFail("expected no error phase, got \(p)")
            }
        }
    }

    // MARK: - test 7: history-expired triggers full re-sync

    func testHistoryIdExpiredTriggersFullResync() async throws {
        let (db, repo, client) = try makeFixture(baseline: "h-old")
        let enumCalls = CounterBox()
        let metaCalls = CounterBox()
        let watcherStarts = CounterBox()
        let providerCalls = CounterBox()

        // Capture the engine for use inside the startWatcher closure.
        let engineHolder = EngineHolder()

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: {
                await providerCalls.incr()
                return "h-new"
            },
            enumerate: { await enumCalls.incr(); return [] },
            syncMetadata: { _ in await metaCalls.incr() },
            fetchBodies: { },
            startWatcher: {
                let count = await watcherStarts.incrAndGet()
                if count == 1 {
                    // Simulate the wired watcher firing onHistoryExpired.
                    if let engine = await engineHolder.value {
                        await engine.handleHistoryExpired()
                    }
                }
            },
            stopWatcher: { },
            startDrain: { },
            stopDrain: { }
        )
        await engineHolder.set(engine)

        let stream = await engine.phaseStream()
        await engine.startSync()
        // First startSync (baseline present) skips straight to .watching where the
        // override fires handleHistoryExpired before returning. The re-sync then
        // takes the full pipeline path; .draining is the post-resync terminal phase.
        _ = try await collectPhases(stream, until: { phase in
            if case .draining = phase { return true }
            return false
        }, timeoutNS: 10_000_000_000)

        do { let v = await watcherStarts.read(); XCTAssertEqual(v, 2) }
        do { let v = await enumCalls.read(); XCTAssertEqual(v, 1) }
        do { let v = await metaCalls.read(); XCTAssertEqual(v, 1) }
        do { let v = await providerCalls.read(); XCTAssertEqual(v, 1) }
        XCTAssertEqual(try repo.allAccounts().first?.historyId, "h-new")

        await engine.stop()
    }

    // MARK: - test 8: phaseStream emits in order to a single subscriber

    func testPhaseStreamEmitsPhasesInOrderOnSingleSubscriber() async throws {
        let (db, repo, client) = try makeFixture(baseline: nil)

        let engine = SyncEngine(
            client: client,
            db: db.queue,
            accountRepo: repo,
            accountID: "acct",
            historyIdProvider: { "h-new" },
            enumerate: { [] },
            syncMetadata: { _ in },
            fetchBodies: { },
            startWatcher: { },
            stopWatcher: { },
            startDrain: { },
            stopDrain: { }
        )

        let stream = await engine.phaseStream()
        await engine.startSync()
        let phases = try await collectPhases(stream, until: { phase in
            if case .draining = phase { return true }
            return false
        })

        // Filter to the distinct progression markers.
        let order: [SyncEngine.Phase] = [
            .idle,
            .enumerating,
            .fetchingMetadata(processed: 0),
            .fetchingBodies(processed: 0),
            .watching,
            .draining
        ]
        let observedIndexes = order.compactMap { target in phases.firstIndex(where: { $0 == target }) }
        XCTAssertEqual(observedIndexes.count, order.count, "expected to see all progression phases, got \(phases)")
        XCTAssertEqual(observedIndexes, observedIndexes.sorted(), "expected phases to appear in monotonic order, got \(phases)")

        await engine.stop()
    }
}

// MARK: - helpers

actor CounterBox {
    private(set) var value: Int = 0
    func incr() { value += 1 }
    func incrAndGet() -> Int { value += 1; return value }
    func read() -> Int { value }
}

actor PhaseCollector {
    var phases: [SyncEngine.Phase] = []
    func append(_ p: SyncEngine.Phase) { phases.append(p) }
}

actor ReleaseGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released: Bool = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        released = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

actor EngineHolder {
    var value: SyncEngine?
    func set(_ engine: SyncEngine) { value = engine }
}
