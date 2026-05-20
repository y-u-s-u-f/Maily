import XCTest
@testable import MailyUI

// MARK: - SidebarItem tests

final class SidebarItemTests: XCTestCase {

    func testAllCasesPresent() {
        let expected: Set<SidebarItem> = [.inbox, .starred, .sent, .drafts]
        XCTAssertEqual(Set(SidebarItem.allCases), expected)
    }

    func testRawValuesAreNonEmpty() {
        for item in SidebarItem.allCases {
            XCTAssertFalse(item.rawValue.isEmpty, "\(item) rawValue must not be empty")
        }
    }

    func testRawValuesAreCapitalized() {
        for item in SidebarItem.allCases {
            let first = String(item.rawValue.prefix(1))
            XCTAssertEqual(first, first.uppercased(), "\(item) rawValue should be capitalized")
        }
    }
}
