import SwiftUI

// MARK: - ReadingPaneView

public struct ReadingPaneView: View {
    public let thread: ThreadRow?

    public init(thread: ThreadRow?) {
        self.thread = thread
    }

    public var body: some View {
        ScrollView {
            if let thread {
                VStack(alignment: .leading, spacing: 16) {
                    Text(thread.subject)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("reading-subject")

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        headerRow(label: "From", value: thread.sender)
                        headerRow(label: "Date",  value: thread.timestamp)
                    }
                    .font(.callout)

                    Divider()

                    Text(thread.snippet)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("reading-snippet")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a thread")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
                    .accessibilityIdentifier("reading-placeholder")
            }
        }
        .accessibilityIdentifier("ReadingPane")
    }

    private func headerRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}
