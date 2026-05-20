import XCTest
@testable import MailyUI
import MailyCore

@MainActor
final class PaletteViewModelTests: XCTestCase {

    // MARK: - Helpers

    /// A registry pre-loaded with `count` commands. Each command's id and
    /// title encode the index so search results are easy to assert on.
    private func makeRegistry(
        count: Int,
        focus: Focus? = nil
    ) async -> (CommandRegistry, [String]) {
        let registry = CommandRegistry()
        var ids: [String] = []
        for i in 0..<count {
            let id = "cmd.\(i)"
            ids.append(id)
            let predicate: @Sendable (CommandContext) -> Bool
            if let focus {
                predicate = { $0.focus == focus }
            } else {
                predicate = { _ in true }
            }
            await registry.register(Command(
                id: id,
                title: "Command \(i)",
                keywords: ["kw\(i)"],
                contextPredicate: predicate,
                handler: { _ in }
            ))
        }
        return (registry, ids)
    }

    private func anyContext() -> CommandContext {
        CommandContext(focus: .list)
    }

    // MARK: - Tests

    // 1. Empty query → results = all commands in context (capped 50).
    func testEmptyQueryReturnsAllCommandsCappedAt50() async {
        let (registry, _) = await makeRegistry(count: 75)
        let vm = PaletteViewModel(registry: registry, context: anyContext())
        await vm.recomputeNow()
        XCTAssertEqual(vm.results.count, PaletteViewModel.resultCap)
        XCTAssertEqual(vm.results.count, 50)
    }

    // 2. Non-empty query → results filtered via registry.search.
    func testNonEmptyQueryFiltersResults() async {
        let registry = CommandRegistry()
        await registry.register(Command(id: "archive", title: "Archive thread", handler: { _ in }))
        await registry.register(Command(id: "delete", title: "Delete thread", handler: { _ in }))
        await registry.register(Command(id: "compose", title: "New message", handler: { _ in }))

        let vm = PaletteViewModel(registry: registry, context: anyContext())
        vm.query = "arch"
        await vm.recomputeNow()

        let ids = vm.results.map(\.id)
        XCTAssertTrue(ids.contains("archive"), "expected archive in \(ids)")
        XCTAssertFalse(ids.contains("compose"))
    }

    // 3. Context change via updateContext → recompute; out-of-context commands disappear.
    func testUpdateContextDropsUnavailableCommands() async {
        let registry = CommandRegistry()
        await registry.register(Command(
            id: "list.only",
            title: "List Only",
            contextPredicate: { $0.focus == .list },
            handler: { _ in }
        ))
        await registry.register(Command(
            id: "always",
            title: "Always",
            handler: { _ in }
        ))

        let vm = PaletteViewModel(registry: registry, context: CommandContext(focus: .list))
        await vm.recomputeNow()
        XCTAssertEqual(Set(vm.results.map(\.id)), ["list.only", "always"])

        vm.updateContext(CommandContext(focus: .compose))
        await vm.recomputeNow()
        XCTAssertEqual(vm.results.map(\.id), ["always"])
    }

    // 4. moveSelection wraps at bounds (last → 0 on +1; 0 → last on −1).
    func testMoveSelectionWrapsAtBounds() async {
        let (registry, _) = await makeRegistry(count: 3)
        let vm = PaletteViewModel(registry: registry, context: anyContext())
        await vm.recomputeNow()
        XCTAssertEqual(vm.results.count, 3)

        vm.selectedIndex = 2
        vm.moveSelection(1)
        XCTAssertEqual(vm.selectedIndex, 0, "advancing past last should wrap to first")

        vm.moveSelection(-1)
        XCTAssertEqual(vm.selectedIndex, 2, "retreating before first should wrap to last")
    }

    // 5. moveSelection with empty results does not crash, leaves selectedIndex at 0.
    func testMoveSelectionWithEmptyResultsIsSafe() async {
        let registry = CommandRegistry()
        let vm = PaletteViewModel(registry: registry, context: anyContext())
        await vm.recomputeNow()
        XCTAssertTrue(vm.results.isEmpty)

        vm.selectedIndex = 0
        vm.moveSelection(1)
        XCTAssertEqual(vm.selectedIndex, 0)
        vm.moveSelection(-1)
        XCTAssertEqual(vm.selectedIndex, 0)
    }

    // 6. activateSelected dispatches the right Command (via a spy actor).
    func testActivateSelectedDispatchesCommand() async {
        // A spy that records the id of any command run through its handler.
        actor Dispatched {
            var ids: [String] = []
            func record(_ id: String) { ids.append(id) }
            func snapshot() -> [String] { ids }
        }
        let spy = Dispatched()

        let registry = CommandRegistry()
        for id in ["alpha", "beta", "gamma"] {
            let capturedID = id
            await registry.register(Command(
                id: id,
                title: id.capitalized,
                handler: { _ in await spy.record(capturedID) }
            ))
        }

        let vm = PaletteViewModel(registry: registry, context: anyContext())
        await vm.recomputeNow()
        vm.selectedIndex = 1
        await vm.activateSelected()

        let ids = await spy.snapshot()
        XCTAssertEqual(ids, ["beta"])
    }

    // 7. activateSelected with empty results is a no-op (no crash, nothing dispatched).
    func testActivateSelectedWithEmptyResultsIsNoop() async {
        actor Dispatched {
            var count = 0
            func bump() { count += 1 }
            func snapshot() -> Int { count }
        }
        let spy = Dispatched()

        let registry = CommandRegistry()
        // A command exists in the registry but is filtered out by context, so
        // results are empty. activateSelected must NOT fire it.
        await registry.register(Command(
            id: "compose.only",
            title: "Compose only",
            contextPredicate: { $0.focus == .compose },
            handler: { _ in await spy.bump() }
        ))

        let vm = PaletteViewModel(registry: registry, context: CommandContext(focus: .list))
        await vm.recomputeNow()
        XCTAssertTrue(vm.results.isEmpty)

        await vm.activateSelected()
        let count = await spy.snapshot()
        XCTAssertEqual(count, 0)
    }

    // 8. Query change resets selectedIndex to 0.
    func testQueryChangeResetsSelectedIndex() async {
        let (registry, _) = await makeRegistry(count: 5)
        let vm = PaletteViewModel(registry: registry, context: anyContext())
        await vm.recomputeNow()
        XCTAssertGreaterThan(vm.results.count, 2)

        vm.selectedIndex = 3
        XCTAssertEqual(vm.selectedIndex, 3)

        vm.query = "Command"
        // The didSet on `query` resets selectedIndex synchronously, before any
        // async recompute lands.
        XCTAssertEqual(vm.selectedIndex, 0)

        await vm.recomputeNow()
        XCTAssertEqual(vm.selectedIndex, 0)
    }

    // MARK: - Extra safety coverage

    // Initial recompute happens automatically after init (via the spawned Task).
    func testInitialRecomputePopulatesResults() async {
        let (registry, _) = await makeRegistry(count: 3)
        let vm = PaletteViewModel(registry: registry, context: anyContext())
        await vm.recomputeNow()
        XCTAssertEqual(vm.results.count, 3)
    }
}
