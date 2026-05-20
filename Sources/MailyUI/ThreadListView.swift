import SwiftUI
import AppKit

// MARK: - Thread row data model

public struct ThreadRow: Identifiable, Sendable {
    public let id: String
    public let sender: String
    public let to: String
    public let subject: String
    public let snippet: String
    public let timestamp: String

    public init(id: String, sender: String, to: String, subject: String, snippet: String, timestamp: String) {
        self.id = id
        self.sender = sender
        self.to = to
        self.subject = subject
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

// MARK: - Hardcoded sample threads

@MainActor public let sampleThreads: [ThreadRow] = [
    ThreadRow(
        id: "t1",
        sender: "GitHub",
        to: "yusuf@maily.app",
        subject: "Your pull request was merged",
        snippet: "PR #42 'feat: add mail window scaffold' was merged into main.",
        timestamp: "9:14 AM"
    ),
    ThreadRow(
        id: "t2",
        sender: "App Store Connect",
        to: "yusuf@maily.app",
        subject: "Weekly summary for Maily",
        snippet: "Crash-free rate: 99.8 %. 12 new downloads this week.",
        timestamp: "Yesterday"
    ),
    ThreadRow(
        id: "t3",
        sender: "stripe-receipts@stripe.com",
        to: "yusuf@maily.app",
        subject: "Your receipt from Stripe",
        snippet: "You were charged $9.00 on May 19, 2026 for Maily Developer Plan.",
        timestamp: "Mon"
    ),
    ThreadRow(
        id: "t4",
        sender: "mom@example.com",
        to: "yusuf@maily.app",
        subject: "Dinner this Friday?",
        snippet: "Hey, are you free Friday evening? Dad wants to try that new place downtown.",
        timestamp: "Sun"
    ),
    ThreadRow(
        id: "t5",
        sender: "noreply@notion.so",
        to: "yusuf@maily.app",
        subject: "[Notion] Someone mentioned you",
        snippet: "Yusuf mentioned you in the page \"Maily roadmap\": @you check this out.",
        timestamp: "Sat"
    ),
    ThreadRow(
        id: "t6",
        sender: "team@linear.app",
        to: "yusuf@maily.app",
        subject: "Issue assigned: M4-α MailWindow scaffold",
        snippet: "A new issue has been assigned to you in the Maily project.",
        timestamp: "Fri"
    ),
    ThreadRow(
        id: "t7",
        sender: "alerts@cloudflare.com",
        to: "yusuf@maily.app",
        subject: "DNS record updated for maily.app",
        snippet: "A DNS record was updated on your account. If this was not you, contact support.",
        timestamp: "Thu"
    ),
]

// MARK: - NSTableView coordinator

public final class ThreadTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public var threads: [ThreadRow]
    public var onSelect: (String?) -> Void

    public init(threads: [ThreadRow], onSelect: @escaping (String?) -> Void) {
        self.threads = threads
        self.onSelect = onSelect
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        threads.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let thread = threads[row]
        let identifier = NSUserInterfaceItemIdentifier("ThreadCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ThreadCellView
        if cell == nil {
            cell = ThreadCellView()
            cell?.identifier = identifier
        }
        cell?.configure(with: thread)
        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        56
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        let row = tableView.selectedRow
        if row >= 0 && row < threads.count {
            onSelect(threads[row].id)
        } else {
            onSelect(nil)
        }
    }
}

// MARK: - Custom cell view

final class ThreadCellView: NSView {
    private let senderLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    private func setupSubviews() {
        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.lineBreakMode = .byTruncatingTail
        timestampLabel.font = .systemFont(ofSize: 11)
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.alignment = .right
        subjectLabel.font = .systemFont(ofSize: 12)
        subjectLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail

        for v in [senderLabel, timestampLabel, subjectLabel, snippetLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            senderLabel.trailingAnchor.constraint(equalTo: timestampLabel.leadingAnchor, constant: -4),

            timestampLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timestampLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            timestampLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80),

            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            snippetLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    func configure(with thread: ThreadRow) {
        senderLabel.stringValue = thread.sender
        timestampLabel.stringValue = thread.timestamp
        subjectLabel.stringValue = thread.subject
        snippetLabel.stringValue = thread.snippet
        setAccessibilityIdentifier("thread-cell-\(thread.id)")
    }
}

// MARK: - NSViewRepresentable wrapper

public struct ThreadListView: NSViewRepresentable {
    public let threads: [ThreadRow]
    @Binding public var selectedThreadID: String?

    public init(threads: [ThreadRow], selectedThreadID: Binding<String?>) {
        self.threads = threads
        _selectedThreadID = selectedThreadID
    }

    public func makeCoordinator() -> ThreadTableCoordinator {
        ThreadTableCoordinator(threads: threads) { [self] id in
            // Coordinator calls back; binding updated on main thread by SwiftUI
            selectedThreadID = id
        }
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.setAccessibilityIdentifier("ThreadListTable")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.rowHeight = 56
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityIdentifier("ThreadListScrollView")
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.threads = threads
        context.coordinator.onSelect = { id in
            selectedThreadID = id
        }
        tableView.reloadData()

        // Sync selection from state
        if let id = selectedThreadID,
           let idx = threads.firstIndex(where: { $0.id == id }) {
            if tableView.selectedRow != idx {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }
}
