import Foundation
import MailyCore

/// View-model for the compose window — handles new messages and replies.
///
/// Outgoing mail goes through the outbox: `send()` builds a
/// `MutationPayload.Send`, wraps it in a `PendingMutation` row with
/// `kind == .send`, and enqueues it via `MutationEnqueuing`. The UI
/// never calls `GmailClient.sendMessage` directly — `MutationDrain`
/// picks the row up and dispatches it.
@MainActor
public final class ComposeViewModel: ObservableObject {

    public enum Mode: Sendable, Equatable {
        case new
        case reply(toMessageID: String, allRecipients: Bool)
    }

    // MARK: - published state

    @Published public var to: String = ""
    @Published public var cc: String = ""
    @Published public var bcc: String = ""
    @Published public var subject: String = ""
    @Published public var body: String = ""

    @Published public private(set) var inReplyTo: String?
    @Published public private(set) var references: [String] = []
    @Published public private(set) var sendError: String?
    @Published public private(set) var isSending: Bool = false

    // MARK: - identity / dependencies

    public let accountID: String
    public let fromAddress: String
    public let mode: Mode

    private let messageRepo: MessageRepository
    private let mutationRepo: any MutationEnqueuing

    /// `threadId` of the source message when replying — passed through
    /// `MutationPayload.Send.threadId` so Gmail keeps the reply in the
    /// same thread. Nil for `.new`.
    private var sourceThreadID: String?

    public init(
        accountID: String,
        fromAddress: String,
        mode: Mode,
        messageRepo: MessageRepository,
        mutationRepo: any MutationEnqueuing
    ) {
        self.accountID = accountID
        self.fromAddress = fromAddress
        self.mode = mode
        self.messageRepo = messageRepo
        self.mutationRepo = mutationRepo
    }

    // MARK: - reply context

    /// Populate the form from the source message. No-op for `.new`. If
    /// the message can't be found locally (e.g. it was deleted between
    /// command dispatch and now) we silently bail — the user can still
    /// fill the form by hand.
    public func loadReplyContext() async {
        guard case let .reply(sourceID, allRecipients) = mode else { return }
        let source: Message?
        do {
            source = try messageRepo.message(id: sourceID)
        } catch {
            return
        }
        guard let source else { return }

        sourceThreadID = source.threadId

        let originalSubject = source.subject ?? ""
        if Self.startsWithReplyPrefix(originalSubject) {
            subject = originalSubject
        } else {
            subject = "Re: \(originalSubject)"
        }

        // For v1 we trust the source's `fromAddr` as a single recipient;
        // we don't try to split a `Name <addr>` style display into parts.
        to = source.fromAddr ?? ""

        if allRecipients {
            // v1 simplification: we DON'T strip our own address from the
            // reply-all cc list. Filtering needs a robust comparison
            // against `fromAddress` (display-name handling, casing) and
            // we'd rather ship the simple version first than ship a
            // subtly-wrong filter.
            let others = source.toAddrs + source.cc
            cc = others.joined(separator: ", ")
        }

        // Synthesized Message-ID — `Message` doesn't persist the
        // RFC-2822 Message-Id header today, so we manufacture one from
        // the Gmail message id. Real-world replies should still thread
        // because we also pass `threadId`. References list ends up
        // single-element for the same reason.
        let synthesizedID = "<\(source.id)@mail.gmail.com>"
        inReplyTo = synthesizedID
        references = [synthesizedID]

        body = Self.quotedReplyBody(source: source)
    }

    /// True when `subject` already begins with `Re:` (case-insensitive) —
    /// used to avoid `Re: Re: Re:` chains.
    static func startsWithReplyPrefix(_ subject: String) -> Bool {
        subject.lowercased().hasPrefix("re:")
    }

    static func quotedReplyBody(source: Message) -> String {
        let when: String = {
            guard let date = source.date else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }()
        let who = source.fromAddr ?? ""
        let raw = (source.bodyText ?? source.snippet ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        // Match the spec's prefix exactly: leading newline so the user's
        // own reply sits on top with whitespace.
        let header = "\nOn \(when) \(who) wrote:\n"
        let quoted = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + String($0) }
            .joined(separator: "\n")
        return header + quoted
    }

    // MARK: - send

    public func send() async {
        guard !isSending else { return }
        isSending = true
        sendError = nil

        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTo.isEmpty, !trimmedSubject.isEmpty, !trimmedBody.isEmpty else {
            sendError = "To, subject, and body are all required."
            isSending = false
            return
        }

        let payload = MutationPayload.Send(
            from: fromAddress,
            to: Self.parseAddressList(to),
            cc: Self.parseAddressList(cc),
            bcc: Self.parseAddressList(bcc),
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references.isEmpty ? nil : references,
            threadId: sourceThreadID
        )

        let json: String
        do {
            json = try MutationPayload.encode(payload)
        } catch {
            sendError = "Failed to encode message: \(error)"
            isSending = false
            return
        }

        let mutation = PendingMutation(
            accountId: accountID,
            kind: .send,
            payloadJson: json
        )

        do {
            _ = try mutationRepo.enqueue(mutation)
        } catch {
            sendError = "Failed to enqueue message: \(error)"
            isSending = false
            return
        }

        // Success: leave the fields alone (the window controller is
        // responsible for closing the window).
        isSending = false
    }

    static func parseAddressList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
