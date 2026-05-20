import XCTest
@testable import MailyUI
import MailyCore

final class KeybindingsLoaderTests: XCTestCase {

    // MARK: - Temp file helpers

    private var tempURLs: [URL] = []

    override func tearDown() async throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try await super.tearDown()
    }

    private func makeTempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keybindings-\(UUID().uuidString).json")
        tempURLs.append(url)
        return url
    }

    // MARK: - Parser tests

    func testParseSingleCharNoModifiers() throws {
        let s = try KeybindingsLoader.parseShortcut("e")
        XCTAssertEqual(s, KeyboardShortcut(key: "e", modifiers: []))
    }

    func testParseCmdK() throws {
        let s = try KeybindingsLoader.parseShortcut("cmd+k")
        XCTAssertEqual(s, KeyboardShortcut(key: "k", modifiers: [.command]))
    }

    func testParseCmdShiftEnter() throws {
        let s = try KeybindingsLoader.parseShortcut("cmd+shift+enter")
        XCTAssertEqual(s, KeyboardShortcut(key: "Enter", modifiers: [.command, .shift]))
    }

    func testParseShiftHash() throws {
        let s = try KeybindingsLoader.parseShortcut("shift+#")
        XCTAssertEqual(s, KeyboardShortcut(key: "#", modifiers: [.shift]))
    }

    func testParseAltIsOption() throws {
        let s = try KeybindingsLoader.parseShortcut("alt+a")
        XCTAssertEqual(s, KeyboardShortcut(key: "a", modifiers: [.option]))
    }

    func testParseCaseInsensitive() throws {
        let s = try KeybindingsLoader.parseShortcut("CMD+Shift+ENTER")
        XCTAssertEqual(s, KeyboardShortcut(key: "Enter", modifiers: [.command, .shift]))
    }

    func testParseSingleCharLowercased() throws {
        let s = try KeybindingsLoader.parseShortcut("K")
        XCTAssertEqual(s, KeyboardShortcut(key: "k", modifiers: []))
    }

    func testParseNamedKeys() throws {
        XCTAssertEqual(try KeybindingsLoader.parseShortcut("tab"),
                       KeyboardShortcut(key: "Tab", modifiers: []))
        XCTAssertEqual(try KeybindingsLoader.parseShortcut("space"),
                       KeyboardShortcut(key: "Space", modifiers: []))
        XCTAssertEqual(try KeybindingsLoader.parseShortcut("esc"),
                       KeyboardShortcut(key: "Escape", modifiers: []))
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try KeybindingsLoader.parseShortcut(""))
    }

    func testParseUnknownModifierThrows() {
        XCTAssertThrowsError(try KeybindingsLoader.parseShortcut("badmod+x"))
    }

    func testParseMultiCharKeyThrows() {
        XCTAssertThrowsError(try KeybindingsLoader.parseShortcut("cmd+foobar"))
    }

    func testParseEmptySegmentThrows() {
        XCTAssertThrowsError(try KeybindingsLoader.parseShortcut("cmd+"))
    }

    // MARK: - loadNow tests

    func testLoadNowMissingFileReturnsEmpty() async throws {
        let url = makeTempURL()
        let loader = KeybindingsLoader(url: url, onChange: { _ in })
        let overrides = try await loader.loadNow()
        XCTAssertEqual(overrides.shortcuts, [:])
    }

    func testLoadNowValidJSON() async throws {
        let url = makeTempURL()
        let json = """
        {
          "shortcuts": {
            "thread.archive": "e",
            "thread.delete": "shift+#",
            "palette.open": "cmd+k",
            "compose.send": "cmd+enter"
          }
        }
        """
        try json.data(using: .utf8)!.write(to: url, options: .atomic)

        let loader = KeybindingsLoader(url: url, onChange: { _ in })
        let overrides = try await loader.loadNow()

        XCTAssertEqual(overrides.shortcuts["thread.archive"],
                       KeyboardShortcut(key: "e", modifiers: []))
        XCTAssertEqual(overrides.shortcuts["thread.delete"],
                       KeyboardShortcut(key: "#", modifiers: [.shift]))
        XCTAssertEqual(overrides.shortcuts["palette.open"],
                       KeyboardShortcut(key: "k", modifiers: [.command]))
        XCTAssertEqual(overrides.shortcuts["compose.send"],
                       KeyboardShortcut(key: "Enter", modifiers: [.command]))
        XCTAssertEqual(overrides.shortcuts.count, 4)
    }

    func testLoadNowMalformedJSONThrows() async throws {
        let url = makeTempURL()
        try "{ not valid json".data(using: .utf8)!.write(to: url, options: .atomic)
        let loader = KeybindingsLoader(url: url, onChange: { _ in })
        await XCTAssertThrowsErrorAsync(try await loader.loadNow())
    }

    func testLoadNowUnparseableShortcutThrows() async throws {
        let url = makeTempURL()
        let json = #"{ "shortcuts": { "x": "cmd+foobar" } }"#
        try json.data(using: .utf8)!.write(to: url, options: .atomic)
        let loader = KeybindingsLoader(url: url, onChange: { _ in })
        await XCTAssertThrowsErrorAsync(try await loader.loadNow())
    }

    // MARK: - Watching tests

    func testStartWatchingFiresOnChange() async throws {
        let url = makeTempURL()
        // Initial content
        let initial = #"{ "shortcuts": { "thread.archive": "e" } }"#
        try initial.data(using: .utf8)!.write(to: url, options: .atomic)

        let exp = expectation(description: "onChange fires after write")
        let receivedBox = ReceivedBox()

        let loader = KeybindingsLoader(url: url, onChange: { overrides in
            await receivedBox.set(overrides)
            exp.fulfill()
        })

        await loader.startWatching()

        // Modify file
        let updated = #"{ "shortcuts": { "palette.open": "cmd+k" } }"#
        try updated.data(using: .utf8)!.write(to: url, options: .atomic)

        await fulfillment(of: [exp], timeout: 5.0)
        await loader.stopWatching()

        let received = await receivedBox.value
        XCTAssertEqual(received?.shortcuts["palette.open"],
                       KeyboardShortcut(key: "k", modifiers: [.command]))
    }

    func testMalformedDuringWatchDoesNotFireOnChange() async throws {
        let url = makeTempURL()
        let initial = #"{ "shortcuts": { "thread.archive": "e" } }"#
        try initial.data(using: .utf8)!.write(to: url, options: .atomic)

        // Two writes: a malformed write (should not fire onChange), then a valid
        // write (should fire). If the loader had crashed or fired onChange for
        // the malformed write, the assertions below would catch it.
        let exp = expectation(description: "valid write fires onChange")
        let receivedBox = ReceivedBox()
        let callCountBox = CallCountBox()

        let loader = KeybindingsLoader(url: url, onChange: { overrides in
            await callCountBox.increment()
            await receivedBox.set(overrides)
            if overrides.shortcuts["palette.open"] != nil {
                exp.fulfill()
            }
        })

        await loader.startWatching()

        // Malformed write
        try "{ not valid json".data(using: .utf8)!.write(to: url, options: .atomic)

        // Give the watcher a moment to process the malformed write
        try await Task.sleep(nanoseconds: 500_000_000)

        // Valid write
        let updated = #"{ "shortcuts": { "palette.open": "cmd+k" } }"#
        try updated.data(using: .utf8)!.write(to: url, options: .atomic)

        await fulfillment(of: [exp], timeout: 5.0)
        await loader.stopWatching()

        let received = await receivedBox.value
        XCTAssertNotNil(received)
        XCTAssertEqual(received?.shortcuts["palette.open"],
                       KeyboardShortcut(key: "k", modifiers: [.command]))
        // The malformed write must NOT have produced an onChange call with
        // empty / garbage Overrides. The only call we expect is the valid one.
        let count = await callCountBox.value
        XCTAssertEqual(count, 1, "onChange should fire only for the valid write")
    }
}

// MARK: - Sendable boxes for test state

private actor ReceivedBox {
    var value: KeybindingsLoader.Overrides?
    func set(_ v: KeybindingsLoader.Overrides) { self.value = v }
}

private actor CallCountBox {
    var value: Int = 0
    func increment() { value += 1 }
}

// MARK: - Async throws helper

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected throw, got success", file: file, line: line)
    } catch {
        // expected
    }
}
