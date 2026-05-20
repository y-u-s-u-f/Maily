import XCTest
import GRDB
@testable import MailyUI
@testable import MailyCore

@MainActor
final class ComposeViewModelTests: XCTestCase {

    // MARK: - fixtures

    private func makeDB() throws -> MailyDatabase {
        let db = try MailyDatabase(location: .inMemory)
        try db.queue.write { try Account(id: "acct", email: "me@example.com").insert($0) }
        return db
    }

    private func insertThread(_ db: MailyDatabase, id: String = "t1") throws {
        try db.queue.write { dbConn in
            try MailThread(id: id, accountId: "acct", labelIds: []).insert(dbConn)
        }
    }

    private func insertSourceMessage(
        _ db: MailyDatabase,
        id: String = "src1",
        threadId: String = "t1",
        from: String = "alice@example.com",
        to: [String] = ["me@example.com"],
        cc: [String] = [],
        subject: String? = "Hello",
        bodyText: String? = "Line one\nLine two"
    ) throws {
        try insertThread(db, id: threadId)
        try db.queue.write { dbConn in
            let m = Message(
                id: id,
                threadId: threadId,
                accountId: "acct",
                fromAddr: from,
                toAddrs: to,
                cc: cc,
                bcc: [],
                subject: subject,
                snippet: bodyText,
                date: Date(timeIntervalSince1970: 1_700_000_000),
                bodyText: bodyText
            )
            try m.insert(dbConn)
        }
    }

    private func makeVM(
        db: MailyDatabase,
        mode: ComposeViewModel.Mode = .new,
        mutationRepo: (any MutationEnqueuing)? = nil
    ) -> ComposeViewModel {
        let msgRepo = MessageRepository(queue: db.queue)
        let mut = mutationRepo ?? MutationRepository(queue: db.queue)
        return ComposeViewModel(
            accountID: "acct",
            fromAddress: "me@example.com",
            mode: mode,
            messageRepo: msgRepo,
            mutationRepo: mut
        )
    }

    private func fetchAllMutations(_ db: MailyDatabase) throws -> [PendingMutation] {
        try db.queue.read { try PendingMutation.fetchAll($0) }
    }

    // MARK: - 1. empty new → validation error, no enqueue

    func testNewModeEmptyFieldsValidationFailsAndDoesNotEnqueue() async throws {
        let db = try makeDB()
        let vm = makeVM(db: db, mode: .new)
        await vm.send()
        XCTAssertNotNil(vm.sendError)
        XCTAssertFalse(vm.isSending)
        XCTAssertEqual(try fetchAllMutations(db).count, 0)
    }

    // MARK: - 2. new → mutation enqueued, payload decodes, kind == "send"

    func testNewModeSuccessfulSendEnqueuesDecodablePayload() async throws {
        let db = try makeDB()
        let vm = makeVM(db: db, mode: .new)
        vm.to = "bob@example.com, carol@example.com"
        vm.cc = "dan@example.com"
        vm.subject = "Hi there"
        vm.body = "Hello"

        await vm.send()

        XCTAssertNil(vm.sendError)
        XCTAssertFalse(vm.isSending)

        let rows = try fetchAllMutations(db)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kindRaw, "send")
        XCTAssertEqual(row.accountId, "acct")

        let payload = try MutationPayload.decode(MutationPayload.Send.self, from: row.payloadJson)
        XCTAssertEqual(payload.from, "me@example.com")
        XCTAssertEqual(payload.to, ["bob@example.com", "carol@example.com"])
        XCTAssertEqual(payload.cc, ["dan@example.com"])
        XCTAssertEqual(payload.bcc, [])
        XCTAssertEqual(payload.subject, "Hi there")
        XCTAssertEqual(payload.body, "Hello")
        XCTAssertNil(payload.inReplyTo)
        XCTAssertNil(payload.references)
        XCTAssertNil(payload.threadId)
    }

    // MARK: - 3. reply: Re: prefix logic, inReplyTo, references

    func testReplyLoadContextPrefixesSubjectAndSetsHeaders() async throws {
        let db = try makeDB()
        try insertSourceMessage(db, subject: "Hello")
        let vm = makeVM(db: db, mode: .reply(toMessageID: "src1", allRecipients: false))
        await vm.loadReplyContext()

        XCTAssertEqual(vm.subject, "Re: Hello")
        XCTAssertEqual(vm.inReplyTo, "<src1@mail.gmail.com>")
        XCTAssertEqual(vm.references, ["<src1@mail.gmail.com>"])
    }

    func testReplyLoadContextDoesNotDoublePrefixWhenAlreadyRe() async throws {
        let db = try makeDB()
        try insertSourceMessage(db, subject: "Re: Hello")
        let vm = makeVM(db: db, mode: .reply(toMessageID: "src1", allRecipients: false))
        await vm.loadReplyContext()
        XCTAssertEqual(vm.subject, "Re: Hello")
    }

    // MARK: - 4. reply (not allRecipients) → to == source.from, cc empty

    func testReplyWithoutAllRecipientsLeavesCcEmpty() async throws {
        let db = try makeDB()
        try insertSourceMessage(
            db,
            from: "alice@example.com",
            to: ["me@example.com", "team@example.com"],
            cc: ["watcher@example.com"]
        )
        let vm = makeVM(db: db, mode: .reply(toMessageID: "src1", allRecipients: false))
        await vm.loadReplyContext()
        XCTAssertEqual(vm.to, "alice@example.com")
        XCTAssertEqual(vm.cc, "")
    }

    // MARK: - 5. reply-all → cc includes source's to + cc

    func testReplyAllPopulatesCcWithOtherRecipients() async throws {
        let db = try makeDB()
        try insertSourceMessage(
            db,
            from: "alice@example.com",
            to: ["me@example.com", "team@example.com"],
            cc: ["watcher@example.com"]
        )
        let vm = makeVM(db: db, mode: .reply(toMessageID: "src1", allRecipients: true))
        await vm.loadReplyContext()
        XCTAssertEqual(vm.to, "alice@example.com")
        // v1 simplification: own address is NOT filtered out.
        XCTAssertEqual(vm.cc, "me@example.com, team@example.com, watcher@example.com")
    }

    // MARK: - 6. enqueued row has accountId == passed-in accountID

    func testEnqueuedRowCarriesAccountID() async throws {
        let db = try makeDB()
        let vm = makeVM(db: db, mode: .new)
        vm.to = "bob@example.com"
        vm.subject = "hi"
        vm.body = "hi"
        await vm.send()
        let rows = try fetchAllMutations(db)
        XCTAssertEqual(rows.first?.accountId, "acct")
    }

    // MARK: - 7. isSending lifecycle

    func testIsSendingFlagFlipsAroundSend() async throws {
        let db = try makeDB()
        let vm = makeVM(db: db, mode: .new)
        vm.to = "bob@example.com"
        vm.subject = "hi"
        vm.body = "hi"
        XCTAssertFalse(vm.isSending)
        await vm.send()
        XCTAssertFalse(vm.isSending)
    }

    /// Captures `isSending` at the moment of enqueue. `vm` is set after
    /// construction so the probe can read back the VM that owns it.
    private final class IsSendingProbe: MutationEnqueuing, @unchecked Sendable {
        let underlying: MutationRepository
        weak var vm: ComposeViewModel?
        var observedIsSending: Bool?
        init(underlying: MutationRepository) { self.underlying = underlying }
        func enqueue(_ mutation: PendingMutation) throws -> Int64 {
            // The VM calls enqueue synchronously on the main actor in
            // the middle of `send()` — reading `isSending` here captures
            // its mid-send value before the post-enqueue reset.
            observedIsSending = MainActor.assumeIsolated { vm?.isSending }
            return try underlying.enqueue(mutation)
        }
    }

    func testIsSendingIsTrueWhileEnqueueRuns() async throws {
        let db = try makeDB()
        let probe = IsSendingProbe(underlying: MutationRepository(queue: db.queue))
        let vm = ComposeViewModel(
            accountID: "acct",
            fromAddress: "me@example.com",
            mode: .new,
            messageRepo: MessageRepository(queue: db.queue),
            mutationRepo: probe
        )
        probe.vm = vm
        vm.to = "bob@example.com"
        vm.subject = "hi"
        vm.body = "hi"
        await vm.send()
        XCTAssertEqual(probe.observedIsSending, true)
        XCTAssertFalse(vm.isSending)
    }

    // MARK: - 8. failed enqueue → sendError set, no row in DB

    private struct ThrowingRepo: MutationEnqueuing {
        struct Boom: Error {}
        func enqueue(_ mutation: PendingMutation) throws -> Int64 { throw Boom() }
    }

    func testEnqueueFailureSurfacesSendError() async throws {
        let db = try makeDB()
        let vm = ComposeViewModel(
            accountID: "acct",
            fromAddress: "me@example.com",
            mode: .new,
            messageRepo: MessageRepository(queue: db.queue),
            mutationRepo: ThrowingRepo()
        )
        vm.to = "bob@example.com"
        vm.subject = "hi"
        vm.body = "hi"
        await vm.send()
        XCTAssertNotNil(vm.sendError)
        XCTAssertFalse(vm.isSending)
        XCTAssertEqual(try fetchAllMutations(db).count, 0)
    }

    // MARK: - reply threading: threadId is propagated to payload

    func testReplySendPropagatesThreadIDIntoPayload() async throws {
        let db = try makeDB()
        try insertSourceMessage(db, threadId: "thread-xyz")
        let vm = makeVM(db: db, mode: .reply(toMessageID: "src1", allRecipients: false))
        await vm.loadReplyContext()
        vm.body = "thanks"
        await vm.send()
        let row = try XCTUnwrap(try fetchAllMutations(db).first)
        let payload = try MutationPayload.decode(MutationPayload.Send.self, from: row.payloadJson)
        XCTAssertEqual(payload.threadId, "thread-xyz")
        XCTAssertEqual(payload.inReplyTo, "<src1@mail.gmail.com>")
        XCTAssertEqual(payload.references, ["<src1@mail.gmail.com>"])
    }
}
