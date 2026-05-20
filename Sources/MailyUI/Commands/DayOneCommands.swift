import Foundation
import MailyCore

public protocol ThreadActions: Sendable {
    func archiveCurrent() async
    func deleteCurrent() async
    func markCurrentRead() async
    // Reserved for a future star command; no day-one command binds this yet.
    func toggleStarCurrent() async
    func openCurrent() async
}

public protocol NavigationActions: Sendable {
    func nextThread() async
    func prevThread() async
}

public protocol ComposeActions: Sendable {
    func openNewCompose() async
    func sendCurrentCompose() async
    func replyToCurrent(replyAll: Bool) async
}

public protocol PaletteActions: Sendable {
    func openPalette() async
}

public enum DayOneCommands {
    @MainActor
    public static func all(
        threadActions: ThreadActions,
        composeActions: ComposeActions,
        navigationActions: NavigationActions,
        paletteActions: PaletteActions
    ) -> [Command] {
        [
            Command(
                id: "thread.next",
                title: "Next thread",
                defaultShortcut: KeyboardShortcut(key: "j"),
                contextPredicate: { $0.focus == .list },
                handler: { _ in await navigationActions.nextThread() }
            ),
            Command(
                id: "thread.prev",
                title: "Previous thread",
                defaultShortcut: KeyboardShortcut(key: "k"),
                contextPredicate: { $0.focus == .list },
                handler: { _ in await navigationActions.prevThread() }
            ),
            Command(
                id: "thread.open",
                title: "Open thread",
                defaultShortcut: KeyboardShortcut(key: "Enter"),
                contextPredicate: { $0.focus == .list },
                handler: { _ in await threadActions.openCurrent() }
            ),
            Command(
                id: "thread.archive",
                title: "Archive thread",
                defaultShortcut: KeyboardShortcut(key: "e"),
                contextPredicate: { $0.focus == .list || $0.focus == .reading },
                handler: { _ in await threadActions.archiveCurrent() }
            ),
            Command(
                id: "thread.delete",
                title: "Delete thread",
                defaultShortcut: KeyboardShortcut(key: "#"),
                contextPredicate: { $0.focus == .list || $0.focus == .reading },
                handler: { _ in await threadActions.deleteCurrent() }
            ),
            Command(
                id: "thread.reply",
                title: "Reply",
                defaultShortcut: KeyboardShortcut(key: "r"),
                contextPredicate: { $0.focus == .reading },
                handler: { _ in await composeActions.replyToCurrent(replyAll: false) }
            ),
            Command(
                id: "thread.replyAll",
                title: "Reply all",
                defaultShortcut: KeyboardShortcut(key: "r", modifiers: .shift),
                contextPredicate: { $0.focus == .reading },
                handler: { _ in await composeActions.replyToCurrent(replyAll: true) }
            ),
            Command(
                id: "thread.markRead",
                title: "Mark as read",
                defaultShortcut: nil,
                handler: { _ in await threadActions.markCurrentRead() }
            ),
            Command(
                id: "compose.new",
                title: "New message",
                defaultShortcut: KeyboardShortcut(key: "c"),
                contextPredicate: { $0.focus != .compose },
                handler: { _ in await composeActions.openNewCompose() }
            ),
            Command(
                id: "palette.open",
                title: "Open command palette",
                defaultShortcut: KeyboardShortcut(key: "k", modifiers: .command),
                handler: { _ in await paletteActions.openPalette() }
            ),
            Command(
                id: "compose.send",
                title: "Send message",
                defaultShortcut: KeyboardShortcut(key: "Enter", modifiers: .command),
                contextPredicate: { $0.focus == .compose },
                handler: { _ in await composeActions.sendCurrentCompose() }
            ),
        ]
    }
}
