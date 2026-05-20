import SwiftUI
import AppKit

/// Minimal v1 compose UI — header fields, plain-text body, send button,
/// error label. No rich-text, no inline attachments, no autosave; those
/// are all explicit follow-ups.
@MainActor
public struct ComposeView: View {
    @ObservedObject public var viewModel: ComposeViewModel

    public init(viewModel: ComposeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("To", text: $viewModel.to)
            field("Cc", text: $viewModel.cc)
            field("Bcc", text: $viewModel.bcc)
            field("Subject", text: $viewModel.subject)

            Divider()

            PlainTextEditor(text: $viewModel.body)
                .frame(minHeight: 240)

            if let error = viewModel.sendError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(viewModel.isSending ? "Sending..." : "Send") {
                    Task { await viewModel.send() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(viewModel.isSending || !canSend)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }

    private var canSend: Bool {
        let trimmedTo = viewModel.to.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = viewModel.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = viewModel.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedTo.isEmpty && !trimmedSubject.isEmpty && !trimmedBody.isEmpty
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 60, alignment: .trailing)
                .foregroundColor(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// Plain-text `NSTextView` wrapper. SwiftUI's `TextEditor` would do most
/// of what we want but doesn't expose a `isRichText = false` knob until
/// macOS 14+ — and we want explicit control over font and rich-text
/// behavior either way, so we wrap `NSTextView` directly.
private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.font = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.delegate = context.coordinator
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
