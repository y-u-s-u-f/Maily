import SwiftUI
import MailyCore

public struct MailWindow: Scene {
    @ObservedObject private var viewModel: InboxViewModel
    private let accountID: String
    private let threadRepo: ThreadRepository
    private let messageRepo: MessageRepository

    public init(
        viewModel: InboxViewModel,
        accountID: String,
        threadRepo: ThreadRepository,
        messageRepo: MessageRepository
    ) {
        self.viewModel = viewModel
        self.accountID = accountID
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
    }

    public var body: some Scene {
        Window("Maily", id: "mail-main") {
            MailRootView(
                viewModel: viewModel,
                accountID: accountID,
                threadRepo: threadRepo,
                messageRepo: messageRepo
            )
        }
        .defaultSize(width: 1100, height: 680)
    }
}

struct MailRootView: View {
    @ObservedObject var viewModel: InboxViewModel
    @StateObject private var readingVM: ReadingPaneViewModel
    @State private var sidebarSelection: SidebarItem = .inbox
    @State private var selectedThreadID: String? = nil

    init(
        viewModel: InboxViewModel,
        accountID: String,
        threadRepo: ThreadRepository,
        messageRepo: MessageRepository
    ) {
        self.viewModel = viewModel
        _readingVM = StateObject(wrappedValue: ReadingPaneViewModel(
            accountID: accountID,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        ))
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
            ReadingPaneView(viewModel: readingVM)
                .frame(minWidth: 400)
                .accessibilityIdentifier("ReadingPane")
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: selectedThreadID) { _, newValue in
            Task { await readingVM.setSelection(newValue) }
        }
    }
}
