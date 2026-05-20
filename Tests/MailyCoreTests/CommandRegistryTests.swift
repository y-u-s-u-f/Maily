import XCTest
@testable import MailyCore

final class CommandRegistryTests: XCTestCase {
    private func makeCommand(
        id: String,
        title: String,
        keywords: [String] = [],
        available: @Sendable @escaping (CommandContext) -> Bool = { _ in true }
    ) -> Command {
        Command(
            id: id,
            title: title,
            subtitle: nil,
            keywords: keywords,
            defaultShortcut: nil,
            contextPredicate: available,
            handler: { _ in }
        )
    }

    private let anyContext = CommandContext(focus: .list, selectedThreadID: nil)

    func testRegisterThenAllReturnsCommand() async {
        let registry = CommandRegistry()
        let cmd = makeCommand(id: "thread.archive", title: "Archive thread")
        await registry.register(cmd)
        let all = await registry.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, "thread.archive")
    }

    func testAllReturnsAllRegisteredCommands() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(id: "a", title: "Alpha"))
        await registry.register(makeCommand(id: "b", title: "Beta"))
        await registry.register(makeCommand(id: "c", title: "Gamma"))
        let all = await registry.all()
        XCTAssertEqual(Set(all.map(\.id)), ["a", "b", "c"])
    }

    func testContextFilteringExcludesUnavailableCommands() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(
            id: "compose.send",
            title: "Send message",
            available: { $0.focus == .compose }
        ))
        await registry.register(makeCommand(
            id: "thread.archive",
            title: "Archive thread",
            available: { $0.focus == .list }
        ))
        let results = await registry.search("", context: CommandContext(focus: .list, selectedThreadID: nil))
        let ids = results.map(\.id)
        XCTAssertTrue(ids.contains("thread.archive"))
        XCTAssertFalse(ids.contains("compose.send"))
    }

    func testFuzzyRankingArcRanksArchiveThreadFirst() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(id: "refresh.archive", title: "Refresh archive folder"))
        await registry.register(makeCommand(id: "thread.archive", title: "Archive thread"))
        let results = await registry.search("arc", context: anyContext)
        XCTAssertEqual(results.first?.id, "thread.archive")
        XCTAssertTrue(results.map(\.id).contains("refresh.archive"))
    }

    func testFuzzyRankingRepRanksReplyAboveReplyAll() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(id: "reply.all", title: "Reply all"))
        await registry.register(makeCommand(id: "reply", title: "Reply"))
        let results = await registry.search("rep", context: anyContext)
        XCTAssertEqual(results.map(\.id), ["reply", "reply.all"])
    }

    func testEmptyQueryReturnsAllContextValidCommands() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(id: "a", title: "Alpha"))
        await registry.register(makeCommand(id: "b", title: "Beta"))
        await registry.register(makeCommand(
            id: "c",
            title: "Gamma",
            available: { _ in false }
        ))
        let results = await registry.search("", context: anyContext)
        XCTAssertEqual(Set(results.map(\.id)), ["a", "b"])
    }

    func testNonMatchingQueryReturnsEmpty() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(id: "a", title: "Alpha"))
        await registry.register(makeCommand(id: "b", title: "Beta"))
        let results = await registry.search("zzzzz", context: anyContext)
        XCTAssertTrue(results.isEmpty)
    }

    func testKeywordsMatchEvenIfTitleDoesNot() async {
        let registry = CommandRegistry()
        await registry.register(makeCommand(
            id: "thread.archive",
            title: "Archive thread",
            keywords: ["e", "shortcut-e"]
        ))
        let results = await registry.search("shortcut", context: anyContext)
        XCTAssertEqual(results.first?.id, "thread.archive")
    }
}
