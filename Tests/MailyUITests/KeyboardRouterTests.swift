import XCTest
@testable import MailyUI
import MailyCore

final class KeyboardRouterTests: XCTestCase {

    // MARK: - Spies

    private actor Spy {
        var fired = false
        var fireCount = 0
        func fire() {
            fired = true
            fireCount += 1
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func makeRouter(
        registry: CommandRegistry,
        focus: Focus = .list
    ) -> KeyboardRouter {
        KeyboardRouter(
            registry: registry,
            contextProvider: { CommandContext(focus: focus, selectedThreadID: nil) }
        )
    }

    // MARK: - Tests

    func testDispatchInvokesMatchingCommand() async {
        let registry = CommandRegistry()
        let spy = Spy()
        let cmd = Command(
            id: "thread.archive",
            title: "Archive thread",
            defaultShortcut: KeyboardShortcut(key: "e"),
            handler: { _ in await spy.fire() }
        )
        await registry.register(cmd)

        let router = await Self.makeRouter(registry: registry)
        await router.refresh()
        await MainActor.run { router.install() }
        defer { Task { @MainActor in router.uninstall() } }

        let context = CommandContext(focus: .list, selectedThreadID: nil)
        let consumed = await router.dispatch(
            shortcut: KeyboardShortcut(key: "e"),
            context: context
        )

        XCTAssertTrue(consumed)
        let fired = await spy.fired
        XCTAssertTrue(fired)

        await MainActor.run { router.uninstall() }
    }

    func testDispatchSkipsWhenContextPredicateFails() async {
        let registry = CommandRegistry()
        let spy = Spy()
        let cmd = Command(
            id: "thread.archive",
            title: "Archive thread",
            defaultShortcut: KeyboardShortcut(key: "e"),
            contextPredicate: { $0.focus != .compose },
            handler: { _ in await spy.fire() }
        )
        await registry.register(cmd)

        let router = await Self.makeRouter(registry: registry)
        await router.refresh()
        await MainActor.run { router.install() }

        let context = CommandContext(focus: .compose, selectedThreadID: nil)
        let consumed = await router.dispatch(
            shortcut: KeyboardShortcut(key: "e"),
            context: context
        )

        XCTAssertFalse(consumed)
        let fired = await spy.fired
        XCTAssertFalse(fired)

        await MainActor.run { router.uninstall() }
    }

    func testDispatchRequiresModifierMatch() async {
        let registry = CommandRegistry()
        let spy = Spy()
        let cmd = Command(
            id: "search.focus",
            title: "Focus search",
            defaultShortcut: KeyboardShortcut(key: "k", modifiers: .command),
            handler: { _ in await spy.fire() }
        )
        await registry.register(cmd)

        let router = await Self.makeRouter(registry: registry)
        await router.refresh()
        await MainActor.run { router.install() }

        let context = CommandContext(focus: .list, selectedThreadID: nil)

        let unmodified = await router.dispatch(
            shortcut: KeyboardShortcut(key: "k"),
            context: context
        )
        XCTAssertFalse(unmodified)
        let firedAfterUnmodified = await spy.fired
        XCTAssertFalse(firedAfterUnmodified)

        let modified = await router.dispatch(
            shortcut: KeyboardShortcut(key: "k", modifiers: .command),
            context: context
        )
        XCTAssertTrue(modified)
        let firedAfterModified = await spy.fired
        XCTAssertTrue(firedAfterModified)

        await MainActor.run { router.uninstall() }
    }

    func testDispatchPicksContextAppropriateCommandAmongDuplicates() async {
        let registry = CommandRegistry()
        let listSpy = Spy()
        let composeSpy = Spy()

        let listCmd = Command(
            id: "list.x",
            title: "List X",
            defaultShortcut: KeyboardShortcut(key: "x"),
            contextPredicate: { $0.focus == .list },
            handler: { _ in await listSpy.fire() }
        )
        let composeCmd = Command(
            id: "compose.x",
            title: "Compose X",
            defaultShortcut: KeyboardShortcut(key: "x"),
            contextPredicate: { $0.focus == .compose },
            handler: { _ in await composeSpy.fire() }
        )
        await registry.register(listCmd)
        await registry.register(composeCmd)

        let router = await Self.makeRouter(registry: registry)
        await router.refresh()
        await MainActor.run { router.install() }

        let listContext = CommandContext(focus: .list, selectedThreadID: nil)
        let consumed = await router.dispatch(
            shortcut: KeyboardShortcut(key: "x"),
            context: listContext
        )

        XCTAssertTrue(consumed)
        let listFired = await listSpy.fired
        let composeFired = await composeSpy.fired
        XCTAssertTrue(listFired)
        XCTAssertFalse(composeFired)

        await MainActor.run { router.uninstall() }
    }

    func testUninstallStopsDispatch() async {
        let registry = CommandRegistry()
        let spy = Spy()
        let cmd = Command(
            id: "thread.archive",
            title: "Archive thread",
            defaultShortcut: KeyboardShortcut(key: "e"),
            handler: { _ in await spy.fire() }
        )
        await registry.register(cmd)

        let router = await Self.makeRouter(registry: registry)
        await router.refresh()
        await MainActor.run {
            router.install()
            router.uninstall()
        }

        let context = CommandContext(focus: .list, selectedThreadID: nil)
        let consumed = await router.dispatch(
            shortcut: KeyboardShortcut(key: "e"),
            context: context
        )

        XCTAssertFalse(consumed)
        let fired = await spy.fired
        XCTAssertFalse(fired)
    }

    func testInstallIsIdempotent() async {
        let registry = CommandRegistry()
        let router = await Self.makeRouter(registry: registry)
        await router.refresh()

        await MainActor.run {
            XCTAssertFalse(router.isInstalledForTesting)
            router.install()
            XCTAssertTrue(router.isInstalledForTesting)
            // Second install must be a no-op and not replace the existing monitor.
            router.install()
            XCTAssertTrue(router.isInstalledForTesting)
            router.uninstall()
            XCTAssertFalse(router.isInstalledForTesting)
        }
    }
}
