// Maintains a synchronous mirror of the actor-backed CommandRegistry so the
// NSEvent local monitor closure (which must return synchronously) can match
// shortcuts without awaiting. Contract: caller registers commands, then calls
// `await router.refresh()`, then calls `router.install()`.
import AppKit
import MailyCore

@MainActor
public final class KeyboardRouter {
    private let registry: CommandRegistry
    private let contextProvider: @MainActor () -> CommandContext
    private var commands: [Command] = []
    private var monitor: Any?

    public init(
        registry: CommandRegistry,
        contextProvider: @escaping @MainActor () -> CommandContext
    ) {
        self.registry = registry
        self.contextProvider = contextProvider
    }

    public func install() {
        // Idempotent: a second call while already installed is a no-op so we
        // never leak a previous NSEvent monitor.
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let shortcut = Self.shortcut(from: event) else { return event }
            let context = self.contextProvider()
            if let command = self.match(shortcut: shortcut, context: context) {
                Task { await command.handler(context) }
                return nil
            }
            return event
        }
    }

    public func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    public func refresh() async {
        let snapshot = await registry.all()
        self.commands = snapshot
    }

    internal func dispatch(shortcut: KeyboardShortcut, context: CommandContext) async -> Bool {
        // Dispatch is only meaningful while the router is installed; this makes
        // `uninstall()` semantically meaningful in tests without having to clear
        // the command snapshot as a side effect.
        guard monitor != nil else { return false }
        guard let command = match(shortcut: shortcut, context: context) else {
            return false
        }
        await command.handler(context)
        return true
    }

    internal var isInstalledForTesting: Bool { monitor != nil }

    private func match(shortcut: KeyboardShortcut, context: CommandContext) -> Command? {
        commands.first { cmd in
            cmd.defaultShortcut == shortcut && cmd.contextPredicate(context)
        }
    }

    private static func shortcut(from event: NSEvent) -> KeyboardShortcut? {
        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else {
            return nil
        }
        let key: String
        switch raw {
        case "\r", "\n": key = "Enter"
        case "\u{1B}":   key = "Escape"
        case "\u{7F}":   key = "Backspace"
        case "\t":       key = "Tab"
        default:         key = raw
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        return KeyboardShortcut(key: key, modifiers: modifiers)
    }
}

@MainActor
public func installKeyboardRouter(
    registry: CommandRegistry,
    contextProvider: @escaping @MainActor () -> CommandContext
) async -> KeyboardRouter {
    let router = KeyboardRouter(registry: registry, contextProvider: contextProvider)
    await router.refresh()
    router.install()
    return router
}
