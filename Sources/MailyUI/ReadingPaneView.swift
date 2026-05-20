import SwiftUI
import MailyCore

private let readingDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

public struct ReadingPaneView: View {
    public let thread: MailThread?

    public init(thread: MailThread?) {
        self.thread = thread
    }

    public var body: some View {
        ScrollView {
            if let thread {
                VStack(alignment: .leading, spacing: 16) {
                    Text(thread.subject ?? "")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("reading-subject")

                    Divider()

                    if let date = thread.lastMessageAt {
                        headerRow(label: "Date", value: readingDateFormatter.string(from: date))
                            .font(.callout)
                    }

                    Divider()

                    Text(thread.snippet ?? "")
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
