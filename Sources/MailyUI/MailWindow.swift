import SwiftUI
import MailyCore

public struct MailWindow: Scene {
    @ObservedObject private var viewModel: InboxViewModel

    public init(viewModel: InboxViewModel) {
        self.viewModel = viewModel
    }

    public var body: some Scene {
        Window("Maily", id: "mail-main") {
            MailRootView(viewModel: viewModel)
        }
        .defaultSize(width: 1100, height: 680)
    }
}

struct MailRootView: View {
    @ObservedObject var viewModel: InboxViewModel
    @State private var sidebarSelection: SidebarItem = .inbox
    @State private var selectedThreadID: String? = nil
    @State private var commandHost: CommandHost?

    private var selectedThread: MailThread? {
        viewModel.threads.first { $0.id == selectedThreadID }
    }

    private var currentFocus: Focus {
        // Best-effort focus inference until M-next wires real focus tracking.
        if selectedThreadID != nil { return .reading }
        return .list
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .frame(minWidth: 180, idealWidth: 180, maxWidth: 180)
                .accessibilityIdentifier("Sidebar")
        } content: {
            ThreadListView(threads: viewModel.threads, selectedThreadID: $selectedThreadID)
                .frame(minWidth: 320, idealWidth: 320, maxWidth: 320)
                .accessibilityIdentifier("ThreadList")
        } detail: {
            ReadingPaneView(thread: selectedThread)
                .frame(minWidth: 400)
                .accessibilityIdentifier("ReadingPane")
        }
        .frame(minWidth: 720, minHeight: 480)
        .task {
            guard commandHost == nil else { return }
            commandHost = await CommandHost.bootstrap(
                contextProvider: { [self] in
                    CommandContext(
                        focus: self.currentFocus,
                        selectedThreadID: self.selectedThreadID
                    )
                }
            )
        }
    }
}
