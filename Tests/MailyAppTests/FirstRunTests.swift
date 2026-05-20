import XCTest
@testable import MailyApp
import MailyUI

final class FirstRunTests: XCTestCase {

    private var tempRoot: URL!
    private var bundledSourceTemp: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-\(UUID().uuidString)", isDirectory: true)
        // Fake bundled source: write a known JSON to a temp file we control.
        bundledSourceTemp = tempRoot.appendingPathComponent("keybindings.default.json")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let json = Data(#"{"shortcuts":{"thread.next":"j"}}"#.utf8)
        try json.write(to: bundledSourceTemp)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    @MainActor
    func testCreatesFileWhenMissing() throws {
        let dest = tempRoot.appendingPathComponent("AppSupport/Maily/keybindings.json")
        try FirstRun.ensureKeybindingsFile(destination: dest, bundledSource: bundledSourceTemp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let copied = try Data(contentsOf: dest)
        let original = try Data(contentsOf: bundledSourceTemp)
        XCTAssertEqual(copied, original)
    }

    @MainActor
    func testLeavesExistingFileUntouched() throws {
        let dest = tempRoot.appendingPathComponent("AppSupport/Maily/keybindings.json")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let existing = Data("{\"shortcuts\":{\"thread.archive\":\"a\"}}".utf8)
        try existing.write(to: dest)

        try FirstRun.ensureKeybindingsFile(destination: dest, bundledSource: bundledSourceTemp)

        let after = try Data(contentsOf: dest)
        XCTAssertEqual(after, existing)
    }

    @MainActor
    func testThrowsWhenBundledSourceNil() {
        let dest = tempRoot.appendingPathComponent("AppSupport/Maily/keybindings.json")
        XCTAssertThrowsError(
            try FirstRun.ensureKeybindingsFile(destination: dest, bundledSource: nil)
        ) { error in
            guard let fr = error as? FirstRun.Error else {
                return XCTFail("Expected FirstRun.Error, got \(error)")
            }
            XCTAssertEqual(fr, .bundledResourceMissing)
        }
    }

    // MARK: - Bundle validity guard

    /// Verify that every entry in the *shipped* keybindings.default.json parses
    /// correctly through KeybindingsLoader.parseShortcut. This is a compile-time
    /// guard against shipping a malformed defaults file.
    @MainActor
    func testShippedDefaultsParseable() throws {
        // Reach into Bundle.module (MailyApp's resource bundle) via the public
        // function surface we expose for tests.
        let bundleURL = FirstRun.bundledDefaultURL()
        guard let url = bundleURL else {
            XCTFail("keybindings.default.json not found in Bundle.module")
            return
        }

        let data = try Data(contentsOf: url)
        struct DiskShape: Decodable { let shortcuts: [String: String] }
        let shape = try JSONDecoder().decode(DiskShape.self, from: data)

        for (id, raw) in shape.shortcuts {
            XCTAssertNoThrow(
                try KeybindingsLoader.parseShortcut(raw),
                "Failed to parse default shortcut for '\(id)': \"\(raw)\""
            )
        }
        // Sanity: there should be exactly 10 entries (all DayOne commands with non-nil shortcuts)
        XCTAssertEqual(shape.shortcuts.count, 10,
                       "Expected 10 default shortcuts, found \(shape.shortcuts.count)")
    }
}
