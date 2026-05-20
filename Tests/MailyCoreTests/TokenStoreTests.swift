import XCTest
@testable import MailyCore

final class InMemoryTokenStoreTests: XCTestCase {

    func testLoadReturnsNilForUnknownAccount() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.loadRefreshToken(account: "nobody@example.com"))
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = InMemoryTokenStore()
        try store.saveRefreshToken("rt-abc", account: "a@example.com")
        XCTAssertEqual(try store.loadRefreshToken(account: "a@example.com"), "rt-abc")
    }

    func testSaveOverwritesExistingToken() throws {
        let store = InMemoryTokenStore()
        try store.saveRefreshToken("first", account: "a@example.com")
        try store.saveRefreshToken("second", account: "a@example.com")
        XCTAssertEqual(try store.loadRefreshToken(account: "a@example.com"), "second")
    }

    func testDeleteRemovesToken() throws {
        let store = InMemoryTokenStore()
        try store.saveRefreshToken("rt", account: "a@example.com")
        try store.deleteRefreshToken(account: "a@example.com")
        XCTAssertNil(try store.loadRefreshToken(account: "a@example.com"))
    }

    func testDeleteUnknownAccountIsNoOp() throws {
        let store = InMemoryTokenStore()
        XCTAssertNoThrow(try store.deleteRefreshToken(account: "nobody@example.com"))
    }

    func testTokensAreIsolatedByAccount() throws {
        let store = InMemoryTokenStore()
        try store.saveRefreshToken("rt-a", account: "a@example.com")
        try store.saveRefreshToken("rt-b", account: "b@example.com")
        XCTAssertEqual(try store.loadRefreshToken(account: "a@example.com"), "rt-a")
        XCTAssertEqual(try store.loadRefreshToken(account: "b@example.com"), "rt-b")
    }
}

final class KeychainTokenStoreTests: XCTestCase {

    /// Unique service per test run so parallel/CI runs don't collide with each
    /// other or pollute the developer's real Keychain entries.
    private var service: String!
    private var store: KeychainTokenStore!

    override func setUp() {
        super.setUp()
        service = "dev.yusuf.maily.tests.\(UUID().uuidString)"
        store = KeychainTokenStore(service: service)
    }

    override func tearDown() {
        try? store.deleteRefreshToken(account: "a@example.com")
        try? store.deleteRefreshToken(account: "b@example.com")
        super.tearDown()
    }

    func testLoadReturnsNilForUnknownAccount() throws {
        XCTAssertNil(try store.loadRefreshToken(account: "a@example.com"))
    }

    func testSaveThenLoadRoundTrips() throws {
        try store.saveRefreshToken("rt-keychain", account: "a@example.com")
        XCTAssertEqual(try store.loadRefreshToken(account: "a@example.com"), "rt-keychain")
    }

    func testSaveOverwritesExistingToken() throws {
        try store.saveRefreshToken("first", account: "a@example.com")
        try store.saveRefreshToken("second", account: "a@example.com")
        XCTAssertEqual(try store.loadRefreshToken(account: "a@example.com"), "second")
    }

    func testDeleteRemovesToken() throws {
        try store.saveRefreshToken("rt", account: "a@example.com")
        try store.deleteRefreshToken(account: "a@example.com")
        XCTAssertNil(try store.loadRefreshToken(account: "a@example.com"))
    }

    func testDeleteUnknownAccountIsNoOp() throws {
        XCTAssertNoThrow(try store.deleteRefreshToken(account: "missing@example.com"))
    }

    func testTokensAreIsolatedByAccount() throws {
        try store.saveRefreshToken("rt-a", account: "a@example.com")
        try store.saveRefreshToken("rt-b", account: "b@example.com")
        XCTAssertEqual(try store.loadRefreshToken(account: "a@example.com"), "rt-a")
        XCTAssertEqual(try store.loadRefreshToken(account: "b@example.com"), "rt-b")
    }
}
