import XCTest
@testable import MailyUI
import MailyCore

final class DayOneCommandsTests: XCTestCase {

    // MARK: - Spies

    private actor ThreadSpy: ThreadActions {
        var archiveCount = 0
        var deleteCount = 0
        var markReadCount = 0
        var toggleStarCount = 0
        var openCount = 0

        func archiveCurrent() async { archiveCount += 1 }
        func deleteCurrent() async { deleteCount += 1 }
        func markCurrentRead() async { markReadCount += 1 }
        func toggleStarCurrent() async { toggleStarCount += 1 }
        func openCurrent() async { openCount += 1 }
    }

    private actor NavigationSpy: NavigationActions {
        var nextCount = 0
        var prevCount = 0
        func nextThread() async { nextCount += 1 }
        func prevThread() async { prevCount += 1 }
    }

    private actor ComposeSpy: ComposeActions {
        var newComposeCount = 0
        var sendCount = 0
        var replyCount = 0
        var lastReplyAll: Bool?

        func openNewCompose() async { newComposeCount += 1 }
        func sendCurrentCompose() async { sendCount += 1 }
        func replyToCurrent(replyAll: Bool) async {
            replyCount += 1
            lastReplyAll = replyAll
        }
    }

    private actor PaletteSpy: PaletteActions {
        var openCount = 0
        func openPalette() async { openCount += 1 }
    }

    // MARK: - Helpers

    private struct Spies {
        let thread: ThreadSpy
        let navigation: NavigationSpy
        let compose: ComposeSpy
        let palette: PaletteSpy
    }

    @MainActor
    private static func makeCommands() -> ([Command], Spies) {
        let spies = Spies(
            thread: ThreadSpy(),
            navigation: NavigationSpy(),
            compose: ComposeSpy(),
            palette: PaletteSpy()
        )
        let commands = DayOneCommands.all(
            threadActions: spies.thread,
            composeActions: spies.compose,
            navigationActions: spies.navigation,
            paletteActions: spies.palette
        )
        return (commands, spies)
    }

    private static func command(_ id: String, in commands: [Command]) -> Command {
        guard let cmd = commands.first(where: { $0.id == id }) else {
            fatalError("Missing command with id \(id)")
        }
        return cmd
    }

    // MARK: - Per-command tests

    func testThreadNext() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.next", in: commands)
        XCTAssertEqual(cmd.title, "Next thread")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "j"))
        let ctx = CommandContext(focus: .list, selectedThreadID: nil)
        XCTAssertTrue(cmd.contextPredicate(ctx))
        await cmd.handler(ctx)
        let count = await spies.navigation.nextCount
        XCTAssertEqual(count, 1)
    }

    func testThreadPrev() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.prev", in: commands)
        XCTAssertEqual(cmd.title, "Previous thread")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "k"))
        let ctx = CommandContext(focus: .list, selectedThreadID: nil)
        XCTAssertTrue(cmd.contextPredicate(ctx))
        await cmd.handler(ctx)
        let count = await spies.navigation.prevCount
        XCTAssertEqual(count, 1)
    }

    func testThreadOpen() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.open", in: commands)
        XCTAssertEqual(cmd.title, "Open thread")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "Enter"))
        let ctx = CommandContext(focus: .list, selectedThreadID: nil)
        XCTAssertTrue(cmd.contextPredicate(ctx))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .reading)))
        await cmd.handler(ctx)
        let count = await spies.thread.openCount
        XCTAssertEqual(count, 1)
    }

    func testThreadArchive() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.archive", in: commands)
        XCTAssertEqual(cmd.title, "Archive thread")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "e"))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .list)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .sidebar)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .compose)))
        await cmd.handler(CommandContext(focus: .list))
        let count = await spies.thread.archiveCount
        XCTAssertEqual(count, 1)
    }

    func testThreadDelete() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.delete", in: commands)
        XCTAssertEqual(cmd.title, "Delete thread")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "#"))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .list)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .compose)))
        await cmd.handler(CommandContext(focus: .reading))
        let count = await spies.thread.deleteCount
        XCTAssertEqual(count, 1)
    }

    func testThreadReply() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.reply", in: commands)
        XCTAssertEqual(cmd.title, "Reply")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "r"))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .list)))
        await cmd.handler(CommandContext(focus: .reading))
        let count = await spies.compose.replyCount
        let replyAll = await spies.compose.lastReplyAll
        XCTAssertEqual(count, 1)
        XCTAssertEqual(replyAll, false)
    }

    func testThreadReplyAll() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.replyAll", in: commands)
        XCTAssertEqual(cmd.title, "Reply all")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "r", modifiers: .shift))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .list)))
        await cmd.handler(CommandContext(focus: .reading))
        let count = await spies.compose.replyCount
        let replyAll = await spies.compose.lastReplyAll
        XCTAssertEqual(count, 1)
        XCTAssertEqual(replyAll, true)
    }

    func testThreadMarkRead() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("thread.markRead", in: commands)
        XCTAssertEqual(cmd.title, "Mark as read")
        XCTAssertNil(cmd.defaultShortcut)
        // No focus restriction.
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .sidebar)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .list)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .compose)))
        await cmd.handler(CommandContext(focus: .list))
        let count = await spies.thread.markReadCount
        XCTAssertEqual(count, 1)
    }

    func testComposeNew() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("compose.new", in: commands)
        XCTAssertEqual(cmd.title, "New message")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "c"))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .sidebar)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .list)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .compose)))
        await cmd.handler(CommandContext(focus: .list))
        let count = await spies.compose.newComposeCount
        XCTAssertEqual(count, 1)
    }

    func testPaletteOpen() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("palette.open", in: commands)
        XCTAssertEqual(cmd.title, "Open command palette")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "k", modifiers: .command))
        // Available in every focus.
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .sidebar)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .list)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .reading)))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .compose)))
        await cmd.handler(CommandContext(focus: .compose))
        let count = await spies.palette.openCount
        XCTAssertEqual(count, 1)
    }

    func testComposeSend() async {
        let (commands, spies) = await Self.makeCommands()
        let cmd = Self.command("compose.send", in: commands)
        XCTAssertEqual(cmd.title, "Send message")
        XCTAssertEqual(cmd.defaultShortcut, KeyboardShortcut(key: "Enter", modifiers: .command))
        XCTAssertTrue(cmd.contextPredicate(CommandContext(focus: .compose)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .list)))
        XCTAssertFalse(cmd.contextPredicate(CommandContext(focus: .reading)))
        await cmd.handler(CommandContext(focus: .compose))
        let count = await spies.compose.sendCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - Sanity

    func testAllReturnsExpectedIds() async {
        let (commands, _) = await Self.makeCommands()
        let ids = Set(commands.map(\.id))
        XCTAssertEqual(ids, [
            "thread.next",
            "thread.prev",
            "thread.open",
            "thread.archive",
            "thread.delete",
            "thread.reply",
            "thread.replyAll",
            "thread.markRead",
            "compose.new",
            "palette.open",
            "compose.send",
        ])
        XCTAssertEqual(commands.count, 11)
    }

    // MARK: - Predicate filtering via registry / router path

    func testRegistrySearchFiltersOutComposeSendFromListFocus() async {
        let (commands, _) = await Self.makeCommands()
        let registry = CommandRegistry()
        for cmd in commands { await registry.register(cmd) }

        let results = await registry.search("", context: CommandContext(focus: .list))
        let ids = results.map(\.id)
        XCTAssertFalse(ids.contains("compose.send"))
        // Sanity: an `.list`-available command IS present.
        XCTAssertTrue(ids.contains("thread.archive"))
    }

    @MainActor
    func testRouterDoesNotDispatchArchiveFromComposeFocus() async {
        let (commands, spies) = Self.makeCommands()
        let registry = CommandRegistry()
        for cmd in commands { await registry.register(cmd) }

        let router = KeyboardRouter(
            registry: registry,
            contextProvider: { CommandContext(focus: .compose) }
        )
        await router.refresh()
        router.install()
        defer { router.uninstall() }

        let consumed = await router.dispatch(
            shortcut: KeyboardShortcut(key: "e"),
            context: CommandContext(focus: .compose)
        )
        XCTAssertFalse(consumed)
        let archiveCount = await spies.thread.archiveCount
        XCTAssertEqual(archiveCount, 0)
    }

    @MainActor
    func testRouterDoesNotDispatchComposeSendFromListFocus() async {
        let (commands, spies) = Self.makeCommands()
        let registry = CommandRegistry()
        for cmd in commands { await registry.register(cmd) }

        let router = KeyboardRouter(
            registry: registry,
            contextProvider: { CommandContext(focus: .list) }
        )
        await router.refresh()
        router.install()
        defer { router.uninstall() }

        let consumed = await router.dispatch(
            shortcut: KeyboardShortcut(key: "Enter", modifiers: .command),
            context: CommandContext(focus: .list)
        )
        XCTAssertFalse(consumed)
        let sendCount = await spies.compose.sendCount
        XCTAssertEqual(sendCount, 0)
        // And `thread.open` (which has Enter no-mods) should not fire either.
        let openCount = await spies.thread.openCount
        XCTAssertEqual(openCount, 0)
    }
}
