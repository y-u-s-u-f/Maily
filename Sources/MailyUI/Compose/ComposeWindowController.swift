import AppKit
import SwiftUI

/// Hosts a single compose VM in its own `NSWindow`. Owns nothing other
/// than the window; the VM is the source of truth for form state and
/// send lifecycle.
@MainActor
public final class ComposeWindowController: NSWindowController, NSWindowDelegate {

    public let viewModel: ComposeViewModel

    public init(viewModel: ComposeViewModel) {
        self.viewModel = viewModel

        let host = NSHostingView(rootView: ComposeView(viewModel: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.title = Self.initialTitle(for: viewModel.mode)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// First-paint title. For `.reply` it's a placeholder until
    /// `loadReplyContext()` populates the subject, after which
    /// `refreshTitle()` swaps in the real one.
    private static func initialTitle(for mode: ComposeViewModel.Mode) -> String {
        switch mode {
        case .new: return "New message"
        case .reply: return "Reply"
        }
    }

    /// Pull the latest subject from the VM and update the window title.
    /// Safe to call any time the subject changes.
    public func refreshTitle() {
        switch viewModel.mode {
        case .new:
            window?.title = "New message"
        case .reply:
            let subj = viewModel.subject.isEmpty ? "" : viewModel.subject
            window?.title = subj.isEmpty ? "Reply" : "Reply: \(subj)"
        }
    }

    /// Drive a send, then close the window if no error surfaced. The
    /// `compose.send` command and the in-window Send button both route
    /// through here so the close-on-success behavior stays in one place.
    public func sendAndClose() async {
        await viewModel.send()
        if viewModel.sendError == nil {
            close()
        }
    }
}
