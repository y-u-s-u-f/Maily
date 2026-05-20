import AppKit
import Foundation
import MailyCore

/// Concrete `ComposeActions` impl that opens compose windows and routes
/// the day-one commands (`compose.new`, `compose.send`, `thread.reply*`)
/// at them.
///
/// "Currently-focused compose window" is tracked as a weak reference,
/// updated when a window becomes key. Closing a window therefore drops
/// the reference automatically — no manual cleanup needed.
@MainActor
public final class ComposeCoordinator: NSObject, ComposeActions, NSWindowDelegate {

    private let accountID: String
    private let fromAddress: String
    private let messageRepo: MessageRepository
    private let mutationRepo: any MutationEnqueuing
    private let currentReadingMessageID: @MainActor @Sendable () -> String?

    /// Windows we've opened but haven't been told are closed. Strong so
    /// the window stays alive while it's on screen; entries are removed
    /// in `windowWillClose(_:)`.
    private var openWindows: [ComposeWindowController] = []
    private weak var focused: ComposeWindowController?

    public init(
        accountID: String,
        fromAddress: String,
        messageRepo: MessageRepository,
        mutationRepo: any MutationEnqueuing,
        currentReadingMessageID: @escaping @MainActor @Sendable () -> String?
    ) {
        self.accountID = accountID
        self.fromAddress = fromAddress
        self.messageRepo = messageRepo
        self.mutationRepo = mutationRepo
        self.currentReadingMessageID = currentReadingMessageID
        super.init()
    }

    // MARK: - ComposeActions

    public func openNewCompose() async {
        let vm = makeViewModel(mode: .new)
        let controller = ComposeWindowController(viewModel: vm)
        present(controller)
    }

    public func sendCurrentCompose() async {
        await focused?.sendAndClose()
    }

    public func replyToCurrent(replyAll: Bool) async {
        guard let id = currentReadingMessageID() else { return }
        let vm = makeViewModel(mode: .reply(toMessageID: id, allRecipients: replyAll))
        await vm.loadReplyContext()
        let controller = ComposeWindowController(viewModel: vm)
        controller.refreshTitle()
        present(controller)
    }

    // MARK: - helpers

    private func makeViewModel(mode: ComposeViewModel.Mode) -> ComposeViewModel {
        ComposeViewModel(
            accountID: accountID,
            fromAddress: fromAddress,
            mode: mode,
            messageRepo: messageRepo,
            mutationRepo: mutationRepo
        )
    }

    private func present(_ controller: ComposeWindowController) {
        // Coordinator becomes the window delegate so we can observe key
        // changes and close events.
        controller.window?.delegate = self
        openWindows.append(controller)
        focused = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        focused = openWindows.first(where: { $0.window === window })
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        openWindows.removeAll(where: { $0.window === window })
        if focused?.window === window { focused = nil }
    }

}
