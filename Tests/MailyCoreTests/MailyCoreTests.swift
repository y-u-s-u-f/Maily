import XCTest
@testable import MailyCore

final class MailyCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(MailyCore.version.isEmpty)
    }
}
