// Bootstraps the command system for the running app: builds the
// CommandRegistry, registers the day-one commands, installs the keyboard
// router, and owns the PaletteWindowController so ⌘K can fire.
//
// PaletteActions and ComposeActions are wired end-to-end as of M9;
// ThreadActions and NavigationActions remain Noop stubs until M10 lands
// the @MainActor selection coordinator that bridges SwiftUI @State
// (selectedThreadID) to the Sendable command closures.
import AppKit
import MailyCore

@MainActor
public final class CommandHost {
    public let registry: CommandRegistry
    public let paletteController: PaletteWindowController
    private let router: KeyboardRouter

    private init(
        registry: CommandRegistry,
        paletteController: PaletteWindowController,
        router: KeyboardRouter
    ) {
        self.registry = registry
        self.paletteController = paletteController
        self.router = router
    }

    public static func bootstrap(
        contextProvider: @escaping @MainActor () -> CommandContext,
        composeActions: ComposeActions
    ) async -> CommandHost {
        let registry = CommandRegistry()
        let paletteController = PaletteWindowController(
            registry: registry,
            contextProvider: contextProvider
        )

        // M9 wires PaletteActions + ComposeActions end-to-end. ThreadActions
        // and NavigationActions stay no-op until a Selection coordinator
        // lands in M10 (see note below).
        let paletteActions = PaletteActionsImpl(controller: paletteController)
        let commands = DayOneCommands.all(
            threadActions: NoopThreadActions(),
            composeActions: composeActions,
            navigationActions: NoopNavigationActions(),
            paletteActions: paletteActions
        )
        for cmd in commands { await registry.register(cmd) }

        let router = await installKeyboardRouter(
            registry: registry,
            contextProvider: contextProvider
        )

        return CommandHost(
            registry: registry,
            paletteController: paletteController,
            router: router
        )
    }
}

// MARK: - Wired

// Concrete PaletteActions binding. We deliberately do NOT store the
// controller as a property (it's @MainActor and not Sendable) — instead we
// snapshot a Sendable closure that hops to MainActor before touching it.
private final class PaletteActionsImpl: PaletteActions, @unchecked Sendable {
    private let controller: PaletteWindowController

    init(controller: PaletteWindowController) {
        self.controller = controller
    }

    func openPalette() async {
        await MainActor.run { [controller] in
            controller.showPalette()
        }
    }
}

// MARK: - Stubs (filled in by later milestones)

// TODO(M10): NoopThreadActions / NoopNavigationActions remain stubs because
// j/k/e have to drive the SwiftUI `selectedThreadID` @State in `MailRootView`.
// That requires a @MainActor selection coordinator owned by `MailyApp` and
// injected into both `MailRootView` and `CommandHost.bootstrap(...)`. The M9
// wire-up audit doesn't list these — they're explicitly tracked for M10.

private struct NoopThreadActions: ThreadActions {
    func archiveCurrent() async {}
    func deleteCurrent() async {}
    func markCurrentRead() async {}
    func toggleStarCurrent() async {}
    func openCurrent() async {}
}

private struct NoopNavigationActions: NavigationActions {
    func nextThread() async {}
    func prevThread() async {}
}
