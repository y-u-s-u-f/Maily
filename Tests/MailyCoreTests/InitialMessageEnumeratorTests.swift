import XCTest
import GRDB
@testable import MailyCore

// A simple thread-safe accumulator for use in @Sendable test closures.
private final class Accumulator<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    var values: [T] {
        lock.withLock { _values }
    }

    func append(_ value: T) {
        lock.withLock { _values.append(value) }
    }
}

final class InitialMessageEnumeratorTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAccountRepo() throws -> AccountRepository {
        let db = try MailyDatabase(location: .inMemory)
        return AccountRepository(queue: db.queue)
    }

    private func oauthResponse(for req: URLRequest) -> (HTTPURLResponse, Data)? {
        guard req.url?.host == "oauth2.googleapis.com" else { return nil }
        return (
            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
        )
    }

    private func messageRefJSON(id: String, threadId: String) -> String {
        #"{"id":"\#(id)","threadId":"\#(threadId)"}"#
    }

    private func listResponseJSON(messages: [(id: String, threadId: String)], nextPageToken: String?) -> String {
        let msgs = messages.map { messageRefJSON(id: $0.id, threadId: $0.threadId) }.joined(separator: ",")
        let tokenField = nextPageToken.map { #","nextPageToken":"\#($0)""# } ?? ""
        return #"{"messages":[\#(msgs)]\#(tokenField)}"#
    }

    // MARK: - Test 1: Single label, one page, no nextPageToken

    func testSingleLabelOnePage() async throws {
        StubURLProtocol.handler = { [self] req in
            if let oauthResp = self.oauthResponse(for: req) { return oauthResp }
            let json = self.listResponseJSON(messages: [("m1", "t1"), ("m2", "t2")], nextPageToken: nil)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let progressEvents = Accumulator<InitialMessageEnumerator.Progress>()
        let accountRepo = try makeAccountRepo()
        let enumerator = InitialMessageEnumerator(
            client: MessagesListTests.makeClient(),
            accountRepo: accountRepo,
            accountID: "acct-1",
            labels: ["INBOX"],
            pageSize: 500,
            onProgress: { progressEvents.append($0) }
        )

        let results = try await enumerator.enumerate()

        XCTAssertEqual(results, [MessageRef(id: "m1", threadId: "t1"), MessageRef(id: "m2", threadId: "t2")])
        XCTAssertEqual(progressEvents.values.count, 1)
        XCTAssertEqual(progressEvents.values[0].label, "INBOX")
        XCTAssertNil(progressEvents.values[0].pageToken)  // first page was fetched with no token
        XCTAssertEqual(progressEvents.values[0].collected, 2)
    }

    // MARK: - Test 2: Single label, 3 pages

    func testSingleLabelThreePages() async throws {
        // page1: nextPageToken=p2, page2: nextPageToken=p3, page3: no token
        let callCounter = Accumulator<Int>()
        StubURLProtocol.handler = { [self] req in
            if let oauthResp = self.oauthResponse(for: req) { return oauthResp }
            let requestIndex = callCounter.values.count
            callCounter.append(requestIndex)
            let json: String
            switch requestIndex {
            case 0:
                json = self.listResponseJSON(messages: [("m1", "t1"), ("m2", "t2")], nextPageToken: "p2")
            case 1:
                json = self.listResponseJSON(messages: [("m3", "t3"), ("m4", "t4")], nextPageToken: "p3")
            default:
                json = self.listResponseJSON(messages: [("m5", "t5")], nextPageToken: nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let progressEvents = Accumulator<InitialMessageEnumerator.Progress>()
        let accountRepo = try makeAccountRepo()
        let enumerator = InitialMessageEnumerator(
            client: MessagesListTests.makeClient(),
            accountRepo: accountRepo,
            accountID: "acct-1",
            labels: ["INBOX"],
            pageSize: 500,
            onProgress: { progressEvents.append($0) }
        )

        let results = try await enumerator.enumerate()
        let events = progressEvents.values

        // 5 messages total, in order
        XCTAssertEqual(results.map(\.id), ["m1", "m2", "m3", "m4", "m5"])

        // onProgress fires 3 times
        XCTAssertEqual(events.count, 3)

        // All are for INBOX label
        XCTAssertTrue(events.allSatisfy { $0.label == "INBOX" })

        // pageToken reflects the token used to FETCH each page
        XCTAssertNil(events[0].pageToken)          // page1 fetched with no token
        XCTAssertEqual(events[1].pageToken, "p2")  // page2 fetched with token "p2"
        XCTAssertEqual(events[2].pageToken, "p3")  // page3 fetched with token "p3"

        // Collected counts strictly increase
        XCTAssertEqual(events[0].collected, 2)
        XCTAssertEqual(events[1].collected, 4)
        XCTAssertEqual(events[2].collected, 5)
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.collected < $1.collected })
    }

    // MARK: - Test 3: Two labels, one page each

    func testTwoLabelsOnePageEach() async throws {
        // INBOX is label[0], SENT is label[1] — requests arrive in that order.
        let callCounter = Accumulator<Int>()
        StubURLProtocol.handler = { [self] req in
            if let oauthResp = self.oauthResponse(for: req) { return oauthResp }
            let requestIndex = callCounter.values.count
            callCounter.append(requestIndex)
            let json: String
            switch requestIndex {
            case 0:
                json = self.listResponseJSON(messages: [("inbox1", "t1"), ("inbox2", "t2")], nextPageToken: nil)
            default:
                json = self.listResponseJSON(messages: [("sent1", "ts1")], nextPageToken: nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let accountRepo = try makeAccountRepo()
        let enumerator = InitialMessageEnumerator(
            client: MessagesListTests.makeClient(),
            accountRepo: accountRepo,
            accountID: "acct-1",
            labels: ["INBOX", "SENT"],
            pageSize: 500
        )

        let results = try await enumerator.enumerate()

        // INBOX messages come first, then SENT
        XCTAssertEqual(results.map(\.id), ["inbox1", "inbox2", "sent1"])
    }

    // MARK: - Test 4: Empty label (no messages key in response)

    func testEmptyLabelNoMessagesKey() async throws {
        StubURLProtocol.handler = { [self] req in
            if let oauthResp = self.oauthResponse(for: req) { return oauthResp }
            // Response has no "messages" key — resultSizeEstimate: 0
            let json = #"{"resultSizeEstimate":0}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let progressEvents = Accumulator<InitialMessageEnumerator.Progress>()
        let accountRepo = try makeAccountRepo()
        let enumerator = InitialMessageEnumerator(
            client: MessagesListTests.makeClient(),
            accountRepo: accountRepo,
            accountID: "acct-1",
            labels: ["INBOX"],
            pageSize: 500,
            onProgress: { progressEvents.append($0) }
        )

        let results = try await enumerator.enumerate()
        let events = progressEvents.values

        XCTAssertEqual(results, [])
        // onProgress fires once even for an empty page
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].collected, 0)
    }

    // MARK: - Test 5: Collected count equals running total across pages

    func testProgressCollectedIsRunningTotal() async throws {
        // 3 pages: 3 msgs, 2 msgs, 4 msgs
        let callCounter = Accumulator<Int>()
        StubURLProtocol.handler = { [self] req in
            if let oauthResp = self.oauthResponse(for: req) { return oauthResp }
            let requestIndex = callCounter.values.count
            callCounter.append(requestIndex)
            let json: String
            switch requestIndex {
            case 0:
                json = self.listResponseJSON(
                    messages: [("a", "t"), ("b", "t"), ("c", "t")],
                    nextPageToken: "tok2"
                )
            case 1:
                json = self.listResponseJSON(
                    messages: [("d", "t"), ("e", "t")],
                    nextPageToken: "tok3"
                )
            default:
                json = self.listResponseJSON(
                    messages: [("f", "t"), ("g", "t"), ("h", "t"), ("i", "t")],
                    nextPageToken: nil
                )
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let collected = Accumulator<Int>()
        let accountRepo = try makeAccountRepo()
        let enumerator = InitialMessageEnumerator(
            client: MessagesListTests.makeClient(),
            accountRepo: accountRepo,
            accountID: "acct-1",
            labels: ["INBOX"],
            pageSize: 500,
            onProgress: { collected.append($0.collected) }
        )

        let results = try await enumerator.enumerate()

        XCTAssertEqual(results.count, 9)
        // Running totals: after page1=3, after page2=5, after page3=9
        XCTAssertEqual(collected.values, [3, 5, 9])
    }
}
