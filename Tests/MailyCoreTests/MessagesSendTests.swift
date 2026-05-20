import XCTest
@testable import MailyCore

final class MessagesSendTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - RFC2822Builder

    func testBuilderSingleRecipientASCII() {
        let msg = OutgoingMessage(
            from: "Alice <alice@example.com>",
            to: ["bob@example.com"],
            subject: "Hello",
            body: "Hi Bob,\nHow are you?"
        )
        let out = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        XCTAssertTrue(out.contains("From: Alice <alice@example.com>\r\n"))
        XCTAssertTrue(out.contains("To: bob@example.com\r\n"))
        XCTAssertTrue(out.contains("Subject: Hello\r\n"))
        XCTAssertTrue(out.contains("Message-ID: <fixed@maily.local>\r\n"))
        XCTAssertTrue(out.contains("MIME-Version: 1.0\r\n"))
        XCTAssertTrue(out.contains("Content-Type: text/plain; charset=UTF-8\r\n"))
        XCTAssertTrue(out.contains("Content-Transfer-Encoding: 7bit\r\n"))
        // Headers and body are separated by a blank line.
        XCTAssertTrue(out.contains("\r\n\r\nHi Bob,\r\nHow are you?"))
    }

    func testBuilderMultipleToAndCc() {
        let msg = OutgoingMessage(
            from: "alice@example.com",
            to: ["bob@example.com", "carol@example.com"],
            cc: ["dave@example.com", "eve@example.com"],
            subject: "Group",
            body: "Hi all"
        )
        let out = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        XCTAssertTrue(out.contains("To: bob@example.com, carol@example.com\r\n"))
        XCTAssertTrue(out.contains("Cc: dave@example.com, eve@example.com\r\n"))
    }

    func testBuilderIncludesBccHeader() {
        let msg = OutgoingMessage(
            from: "alice@example.com",
            to: ["bob@example.com"],
            bcc: ["secret@example.com"],
            subject: "Quiet",
            body: "shh"
        )
        let out = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        XCTAssertTrue(out.contains("Bcc: secret@example.com\r\n"))
    }

    func testBuilderEncodesNonASCIISubjectAsRFC2047() {
        let msg = OutgoingMessage(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "Café meeting — 会議",
            body: "ascii body"
        )
        let out = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        let expected = "=?UTF-8?B?" + Data("Café meeting — 会議".utf8).base64EncodedString() + "?="
        XCTAssertTrue(out.contains("Subject: \(expected)\r\n"),
                      "Subject should be RFC 2047 B-encoded. Got:\n\(out)")
    }

    func testBuilderEncodesNonASCIIDisplayName() {
        let msg = OutgoingMessage(
            from: "Müller <m@example.com>",
            to: ["bob@example.com"],
            subject: "Hi",
            body: "ascii"
        )
        let out = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        let expected = "=?UTF-8?B?" + Data("Müller".utf8).base64EncodedString() + "?="
        XCTAssertTrue(out.contains("From: \(expected) <m@example.com>\r\n"),
                      "Display name should be RFC 2047 B-encoded. Got:\n\(out)")
    }

    func testBuilderDeterministicWithInjectedDateAndMessageID() {
        let msg = OutgoingMessage(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "Pin",
            body: "body"
        )
        let a = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        let b = RFC2822Builder.build(msg, date: fixedDate, messageID: "<fixed@maily.local>")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("Date: Mon, 04 May 2026 12:34:56 +0000\r\n"))
        XCTAssertTrue(a.contains("Message-ID: <fixed@maily.local>\r\n"))
    }

    // MARK: - endpoint

    func testSendMessagePostsRawAndThreadIdToCorrectPath() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            XCTAssertEqual(
                req.url?.absoluteString,
                "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
            )
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(json?["threadId"] as? String, "t-123")
            let raw = json?["raw"] as? String ?? ""
            XCTAssertFalse(raw.isEmpty)
            // base64url: no padding, no + or /
            XCTAssertFalse(raw.contains("="))
            XCTAssertFalse(raw.contains("+"))
            XCTAssertFalse(raw.contains("/"))
            // Round-trip and verify the decoded text is a real RFC 2822 message.
            let decoded = Self.base64URLDecode(raw)
            let asString = String(data: decoded, encoding: .utf8) ?? ""
            XCTAssertTrue(asString.contains("To: bob@example.com\r\n"))
            XCTAssertTrue(asString.contains("Subject: Hi\r\n"))
            XCTAssertTrue(asString.contains("\r\n\r\nhello"))
            let body = Data(#"{"id":"m-1","threadId":"t-123","labelIds":["SENT"]}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = GmailClientTests.makeClient()
        let msg = OutgoingMessage(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "Hi",
            body: "hello"
        )
        let resp = try await client.sendMessage(msg, threadId: "t-123")
        XCTAssertEqual(resp, SendMessageResponse(id: "m-1", threadId: "t-123", labelIds: ["SENT"]))
    }

    func testSendMessageOmitsThreadIdWhenNil() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8))
            }
            let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertNotNil(json?["raw"])
            XCTAssertNil(json?["threadId"])
            let body = Data(#"{"id":"m-2","threadId":"t-2"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = GmailClientTests.makeClient()
        let msg = OutgoingMessage(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "S",
            body: "B"
        )
        let resp = try await client.sendMessage(msg)
        XCTAssertEqual(resp.id, "m-2")
        XCTAssertEqual(resp.threadId, "t-2")
    }

    // MARK: - helpers

    /// 2026-05-04 12:34:56 UTC — arbitrary but pinned for deterministic Date headers.
    private var fixedDate: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 4
        comps.hour = 12
        comps.minute = 34
        comps.second = 56
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: comps)!
    }

    private static func base64URLDecode(_ s: String) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        return Data(base64Encoded: t) ?? Data()
    }
}
