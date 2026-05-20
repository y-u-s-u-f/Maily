import XCTest
@testable import MailyUI

// MARK: - SampleThread data tests

@MainActor
final class SampleThreadDataTests: XCTestCase {

    func testSampleThreadsNotEmpty() {
        XCTAssertFalse(sampleThreads.isEmpty, "sampleThreads must not be empty")
    }

    func testSampleThreadCountInRange() {
        XCTAssertGreaterThanOrEqual(sampleThreads.count, 5)
        XCTAssertLessThanOrEqual(sampleThreads.count, 8)
    }

    func testAllThreadIDsUnique() {
        let ids = sampleThreads.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Thread IDs must be unique")
    }

    func testNoEmptyFields() {
        for thread in sampleThreads {
            XCTAssertFalse(thread.id.isEmpty,        "Thread id must not be empty: \(thread)")
            XCTAssertFalse(thread.sender.isEmpty,    "Thread sender must not be empty: \(thread)")
            XCTAssertFalse(thread.to.isEmpty,        "Thread to must not be empty: \(thread)")
            XCTAssertFalse(thread.subject.isEmpty,   "Thread subject must not be empty: \(thread)")
            XCTAssertFalse(thread.snippet.isEmpty,   "Thread snippet must not be empty: \(thread)")
            XCTAssertFalse(thread.timestamp.isEmpty, "Thread timestamp must not be empty: \(thread)")
        }
    }
}

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

// MARK: - ThreadRow initializer tests

final class ThreadRowTests: XCTestCase {

    func testThreadRowStoresAllProperties() {
        let row = ThreadRow(
            id: "x1",
            sender: "Alice",
            to: "bob@example.com",
            subject: "Hello",
            snippet: "Hello there",
            timestamp: "10:00 AM"
        )
        XCTAssertEqual(row.id, "x1")
        XCTAssertEqual(row.sender, "Alice")
        XCTAssertEqual(row.to, "bob@example.com")
        XCTAssertEqual(row.subject, "Hello")
        XCTAssertEqual(row.snippet, "Hello there")
        XCTAssertEqual(row.timestamp, "10:00 AM")
    }

    func testThreadRowIdentifiableByID() {
        let row1 = ThreadRow(id: "a", sender: "A", to: "a@example.com", subject: "A", snippet: "A", timestamp: "A")
        let row2 = ThreadRow(id: "b", sender: "B", to: "b@example.com", subject: "B", snippet: "B", timestamp: "B")
        XCTAssertNotEqual(row1.id, row2.id)
    }
}
