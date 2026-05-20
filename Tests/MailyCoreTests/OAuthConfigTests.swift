import XCTest
@testable import MailyCore

final class OAuthConfigTests: XCTestCase {

    private func writeTempJSON(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadParsesAllFields() throws {
        let url = try writeTempJSON("""
        {
          "client_id": "abc.apps.googleusercontent.com",
          "client_secret": "shh",
          "redirect_uri": "http://127.0.0.1/oauth/callback"
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try OAuthConfig.load(from: url)
        XCTAssertEqual(cfg.clientID, "abc.apps.googleusercontent.com")
        XCTAssertEqual(cfg.clientSecret, "shh")
        XCTAssertEqual(cfg.redirectURI, "http://127.0.0.1/oauth/callback")
    }

    func testLoadThrowsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertThrowsError(try OAuthConfig.load(from: url))
    }

    func testLoadThrowsOnPlaceholderClientID() throws {
        let url = try writeTempJSON("""
        {
          "client_id": "YOUR-CLIENT-ID.apps.googleusercontent.com",
          "client_secret": "real-secret",
          "redirect_uri": "http://127.0.0.1/oauth/callback"
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try OAuthConfig.load(from: url)) { error in
            guard case OAuthConfig.LoadError.placeholderCredentials = error else {
                return XCTFail("expected placeholderCredentials, got \(error)")
            }
        }
    }

    func testLoadThrowsOnPlaceholderSecret() throws {
        let url = try writeTempJSON("""
        {
          "client_id": "real.apps.googleusercontent.com",
          "client_secret": "YOUR-CLIENT-SECRET",
          "redirect_uri": "http://127.0.0.1/oauth/callback"
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try OAuthConfig.load(from: url)) { error in
            guard case OAuthConfig.LoadError.placeholderCredentials = error else {
                return XCTFail("expected placeholderCredentials, got \(error)")
            }
        }
    }

    func testLoadThrowsOnMalformedJSON() throws {
        let url = try writeTempJSON("{ not json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try OAuthConfig.load(from: url))
    }

    func testRedirectPortReturnsNilForUnspecifiedPort() throws {
        let cfg = OAuthConfig(
            clientID: "x",
            clientSecret: "y",
            redirectURI: "http://127.0.0.1/oauth/callback"
        )
        XCTAssertNil(cfg.redirectPort)
        XCTAssertEqual(cfg.redirectPath, "/oauth/callback")
    }

    func testRedirectPortParsesExplicitPort() throws {
        let cfg = OAuthConfig(
            clientID: "x",
            clientSecret: "y",
            redirectURI: "http://127.0.0.1:54321/oauth/callback"
        )
        XCTAssertEqual(cfg.redirectPort, 54321)
        XCTAssertEqual(cfg.redirectPath, "/oauth/callback")
    }
}
