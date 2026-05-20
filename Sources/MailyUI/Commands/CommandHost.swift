// Bootstraps the command system for the running app: builds the
// CommandRegistry, registers the day-one commands, installs the keyboard
// router, and owns the PaletteWindowController so ⌘K can fire.
//
// Thread/Compose/Navigation action stubs live here until later milestones
// connect them to real handlers. PaletteActions is the only action protocol
// fully wired in M6.
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
        contextProvider: @escaping @MainActor () -> CommandContext
    ) async -> CommandHost {
        let registry = CommandRegistry()
        let paletteController = PaletteWindowController(
            registry: registry,
            contextProvider: contextProvider
        )

        // M6 only wires PaletteActions end-to-end; the rest are no-op stubs
        // until later milestones bind real handlers.
        let paletteActions = PaletteActionsImpl(controller: paletteController)
        let commands = DayOneCommands.all(
            threadActions: NoopThreadActions(),
            composeActions: NoopComposeActions(),
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

private struct NoopComposeActions: ComposeActions {
    func openNewCompose() async {}
    func sendCurrentCompose() async {}
    func replyToCurrent(replyAll: Bool) async {}
}
