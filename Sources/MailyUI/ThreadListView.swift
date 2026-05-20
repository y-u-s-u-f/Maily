import SwiftUI
import AppKit
import MailyCore

// MARK: - Timestamp formatter

private let threadTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

private let threadDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .none
    return f
}()

private func formatTimestamp(_ date: Date?) -> String {
    guard let date else { return "" }
    if Calendar.current.isDateInToday(date) {
        return threadTimeFormatter.string(from: date)
    }
    return threadDateFormatter.string(from: date)
}

// MARK: - NSTableView coordinator

public final class ThreadTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var threads: [MailThread]
    var onSelect: (String?) -> Void

    init(threads: [MailThread], onSelect: @escaping (String?) -> Void) {
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
    private let subjectLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
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
        subjectLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subjectLabel.lineBreakMode = .byTruncatingTail
        timestampLabel.font = .systemFont(ofSize: 11)
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.alignment = .right
        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail

        for v in [subjectLabel, timestampLabel, snippetLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subjectLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            timestampLabel.leadingAnchor.constraint(equalTo: subjectLabel.trailingAnchor, constant: 4),
            timestampLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timestampLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            timestampLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),

            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            snippetLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    func configure(with thread: MailThread) {
        subjectLabel.stringValue = thread.subject ?? ""
        timestampLabel.stringValue = formatTimestamp(thread.lastMessageAt)
        snippetLabel.stringValue = thread.snippet ?? ""
        setAccessibilityIdentifier("thread-cell-\(thread.id)")
    }
}

// MARK: - NSViewRepresentable wrapper

public struct ThreadListView: NSViewRepresentable {
    public let threads: [MailThread]
    @Binding public var selectedThreadID: String?

    public init(threads: [MailThread], selectedThreadID: Binding<String?>) {
        self.threads = threads
        _selectedThreadID = selectedThreadID
    }

    public func makeCoordinator() -> ThreadTableCoordinator {
        ThreadTableCoordinator(threads: threads, onSelect: { _ in })
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

        if context.coordinator.threads != threads {
            context.coordinator.threads = threads
            tableView.reloadData()
        }

        context.coordinator.onSelect = { id in
            selectedThreadID = id
        }

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
