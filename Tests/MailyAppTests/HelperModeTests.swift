import XCTest
@testable import MailyApp

final class HelperModeTests: XCTestCase {
    func testParseNormalWithNoFlags() {
        XCTAssertEqual(HelperMode.parse(["maily"]), .normal)
    }

    func testParseSyncOnly() {
        XCTAssertEqual(HelperMode.parse(["maily", "--sync-only"]), .syncOnly)
    }

    // Additional coverage — sanity check that argv[0] is ignored, mirroring
    // the docstring on `parse(_:)`. Kept because it's free and pins behavior
    // future refactors might regress.
    func testParseIgnoresArgv0() {
        XCTAssertEqual(HelperMode.parse(["--sync-only"]), .normal,
                       "argv[0] is the process name and must be ignored")
    }
}
