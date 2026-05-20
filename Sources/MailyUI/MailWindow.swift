import SwiftUI

// MARK: - MailWindow Scene

public struct MailWindow: Scene {
    public init() {}

    public var body: some Scene {
        Window("Maily", id: "mail-main") {
            MailRootView()
        }
        .defaultSize(width: 1100, height: 680)
    }
}

// MARK: - MailRootView

/// Root content view — owns all top-level @State.
struct MailRootView: View {
    @State private var sidebarSelection: SidebarItem = .inbox
    @State private var selectedThreadID: String? = nil

    private var selectedThread: ThreadRow? {
        sampleThreads.first { $0.id == selectedThreadID }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .frame(minWidth: 180, idealWidth: 180, maxWidth: 180)
                .accessibilityIdentifier("Sidebar")
        } content: {
            ThreadListView(threads: sampleThreads, selectedThreadID: $selectedThreadID)
                .frame(minWidth: 320, idealWidth: 320, maxWidth: 320)
                .accessibilityIdentifier("ThreadList")
        } detail: {
            ReadingPaneView(thread: selectedThread)
                .frame(minWidth: 400)
                .accessibilityIdentifier("ReadingPane")
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
