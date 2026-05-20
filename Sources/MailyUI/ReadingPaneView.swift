import SwiftUI
import MailyCore

private let readingDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

public struct ReadingPaneView: View {
    @ObservedObject public var viewModel: ReadingPaneViewModel

    public init(viewModel: ReadingPaneViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            if viewModel.isLoading {
                ProgressView()
                    .padding(.top, 80)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("reading-loading")
            } else if let error = viewModel.loadError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 80)
                    .accessibilityIdentifier("reading-error")
            } else if let thread = viewModel.thread {
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

                    ForEach(viewModel.messages, id: \.id) { message in
                        messageRow(message)
                    }
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

    private func messageRow(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.fromAddr ?? "")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(message.bodyText ?? message.snippet ?? "")
                .font(.body)
                .foregroundStyle(.primary)
            Divider()
        }
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
