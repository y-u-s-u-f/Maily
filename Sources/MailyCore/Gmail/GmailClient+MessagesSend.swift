import Foundation

/// User-facing draft of an outgoing email. v1 supports plain-text only;
/// HTML alternatives and attachments will land in a later commit and will
/// extend `OutgoingMessage` rather than replace it.
public struct OutgoingMessage: Sendable {
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let body: String
    public let inReplyTo: String?
    public let references: [String]?

    public init(
        from: String,
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: [String]? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// Minimal slice of Gmail's Message resource that the send endpoint returns.
public struct SendMessageResponse: Decodable, Equatable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?

    public init(id: String, threadId: String, labelIds: [String]? = nil) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
    }
}

/// Pure builder for the RFC 2822 wire representation Gmail expects in the
/// `raw` field. Kept as a free enum so tests can exercise it without a
/// `GmailClient` or any network plumbing.
public enum RFC2822Builder {

    /// `date` and `messageID` are injectable so test output is byte-stable.
    public static func build(
        _ message: OutgoingMessage,
        date: Date = Date(),
        messageID: String = defaultMessageID()
    ) -> String {
        var lines: [String] = []
        lines.append("From: \(encodeAddressList([message.from]))")
        if !message.to.isEmpty {
            lines.append("To: \(encodeAddressList(message.to))")
        }
        if !message.cc.isEmpty {
            lines.append("Cc: \(encodeAddressList(message.cc))")
        }
        // Bcc is included in the headers we hand Gmail; Gmail strips it before
        // delivery to recipients but uses it to decide who to deliver to.
        if !message.bcc.isEmpty {
            lines.append("Bcc: \(encodeAddressList(message.bcc))")
        }
        lines.append("Subject: \(encodeHeaderValue(message.subject))")
        lines.append("Date: \(rfc2822Date(date))")
        lines.append("Message-ID: \(messageID)")
        if let inReplyTo = message.inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let refs = message.references, !refs.isEmpty {
            lines.append("References: \(refs.joined(separator: " "))")
        }
        lines.append("MIME-Version: 1.0")
        let bodyIsASCII = message.body.allSatisfy { $0.isASCII }
        if bodyIsASCII {
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("Content-Transfer-Encoding: 7bit")
        } else {
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
        }

        let headerBlock = lines.joined(separator: "\r\n")
        let encodedBody = bodyIsASCII
            ? normalizeCRLF(message.body)
            : quotedPrintable(message.body)
        return headerBlock + "\r\n\r\n" + encodedBody
    }

    public static func defaultMessageID() -> String {
        "<\(UUID().uuidString)@maily.local>"
    }

    // MARK: - header encoding

    /// Encode each `Name <addr>` or bare `addr` entry, RFC 2047-encoding the
    /// display name if it contains non-ASCII, then join with `, `.
    static func encodeAddressList(_ addrs: [String]) -> String {
        addrs.map(encodeSingleAddress).joined(separator: ", ")
    }

    static func encodeSingleAddress(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Match `Display Name <addr@host>` (display name optional).
        guard let lt = trimmed.lastIndex(of: "<"),
              trimmed.hasSuffix(">"),
              lt > trimmed.startIndex
        else {
            return trimmed
        }
        let nameRange = trimmed.startIndex..<lt
        let name = String(trimmed[nameRange]).trimmingCharacters(in: .whitespaces)
        let addr = String(trimmed[lt...])
        let unquotedName = stripSurroundingQuotes(name)
        if unquotedName.allSatisfy({ $0.isASCII }) {
            return name.isEmpty ? addr : "\(name) \(addr)"
        }
        return "\(rfc2047EncodedWord(unquotedName)) \(addr)"
    }

    static func stripSurroundingQuotes(_ s: String) -> String {
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// RFC 2047 encoded-word for header text. Non-ASCII -> single B-encoded
    /// word over the whole value. ASCII passes through untouched.
    static func encodeHeaderValue(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) {
            return value
        }
        return rfc2047EncodedWord(value)
    }

    static func rfc2047EncodedWord(_ text: String) -> String {
        let b64 = Data(text.utf8).base64EncodedString()
        return "=?UTF-8?B?\(b64)?="
    }

    // MARK: - body encoding

    /// Naive QP encoder sufficient for short plain-text bodies. Encodes any
    /// byte outside the printable ASCII range, plus `=` itself, and
    /// normalizes line endings to CRLF. Does not enforce the 76-char line
    /// limit — Gmail accepts longer lines and the v1 UI doesn't produce them
    /// in practice.
    static func quotedPrintable(_ text: String) -> String {
        let normalized = normalizeCRLF(text)
        var out = ""
        for byte in normalized.utf8 {
            switch byte {
            case 0x09, 0x20...0x3C, 0x3E...0x7E:
                out.append(Character(UnicodeScalar(byte)))
            case 0x0D, 0x0A:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(String(format: "=%02X", byte))
            }
        }
        return out
    }

    static func normalizeCRLF(_ text: String) -> String {
        // Collapse any \r\n to \n first, then expand all \n to \r\n.
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
        return lf.replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: - date

    static func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}

extension GmailClient {

    /// Send `message` via `users.messages.send`. Pass `threadId` to make the
    /// outgoing message land inside an existing thread (Gmail also requires
    /// the `In-Reply-To`/`References` headers for proper threading; populate
    /// those on `OutgoingMessage` when replying).
    public func sendMessage(
        _ message: OutgoingMessage,
        threadId: String? = nil
    ) async throws -> SendMessageResponse {
        let rfc2822 = RFC2822Builder.build(message)
        let raw = Data(rfc2822.utf8).base64URLEncodedString()
        var body: [String: Any] = ["raw": raw]
        if let threadId {
            body["threadId"] = threadId
        }
        return try await postJSON("messages/send", queryItems: [], json: body)
    }
}
