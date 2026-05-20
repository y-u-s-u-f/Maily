import XCTest
@testable import MailyCore

final class AuthenticatedSessionTests: XCTestCase {

    private let config = OAuthConfig(
        clientID: "c",
        clientSecret: "s",
        redirectURI: "http://127.0.0.1/oauth/callback"
    )
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let api = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession(
        refreshToken: String = "rt",
        cachedAccessToken: TokenCache? = nil,
        sleeps: SleepRecorder = SleepRecorder()
    ) -> AuthenticatedSession {
        let store = InMemoryTokenStore()
        try? store.saveRefreshToken(refreshToken, account: "a@example.com")
        let urlSession = URLSession.stubbed()
        let endpoint = TokenEndpoint(config: config, session: urlSession)
        return AuthenticatedSession(
            account: "a@example.com",
            tokenStore: store,
            tokenEndpoint: endpoint,
            session: urlSession,
            cachedToken: cachedAccessToken,
            sleeper: { interval in await sleeps.record(interval) }
        )
    }

    // MARK: - happy path

    func testFreshTokenRequestSucceeds() async throws {
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                return (Self.ok, Self.tokenJSON(access: "at-1", expires: 3600))
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer at-1")
            return (Self.ok, Data("{\"ok\":true}".utf8))
        }
        let session = makeSession()
        let (data, response) = try await session.data(for: URLRequest(url: api))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"ok\":true}")
    }

    func testCachedTokenSkipsRefresh() async throws {
        let calls = LockBox<Int>(0)
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                calls.set(calls.get() + 1)
                return (Self.ok, Self.tokenJSON(access: "should-not-be-used", expires: 3600))
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer cached")
            return (Self.ok, Data())
        }
        let cache = TokenCache(accessToken: "cached", expiresAt: Date().addingTimeInterval(600))
        let session = makeSession(cachedAccessToken: cache)
        _ = try await session.data(for: URLRequest(url: api))
        XCTAssertEqual(calls.get(), 0, "should not have hit token endpoint")
    }

    // MARK: - 401 refresh

    func testFirst401TriggersRefreshThenRetries() async throws {
        let phase = LockBox<Int>(0)
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                let body = phase.get() == 0
                    ? Self.tokenJSON(access: "at-old", expires: 3600)
                    : Self.tokenJSON(access: "at-new", expires: 3600)
                phase.set(phase.get() + 1)
                return (Self.ok, body)
            }
            let auth = req.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer at-old" {
                return (Self.status(401), Data("{\"error\":\"unauthorized\"}".utf8))
            }
            XCTAssertEqual(auth, "Bearer at-new")
            return (Self.ok, Data("retried-ok".utf8))
        }
        let session = makeSession()
        let (data, response) = try await session.data(for: URLRequest(url: api))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "retried-ok")
    }

    func testTwoConsecutive401sThrowsNeedsReauth() async {
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                return (Self.ok, Self.tokenJSON(access: "at", expires: 3600))
            }
            return (Self.status(401), Data())
        }
        let session = makeSession()
        do {
            _ = try await session.data(for: URLRequest(url: api))
            XCTFail("expected throw")
        } catch AuthenticatedSessionError.needsReauth {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - 429 / 5xx backoff

    func testRetriesOn429RespectingRetryAfter() async throws {
        let phase = LockBox<Int>(0)
        let sleeps = SleepRecorder()
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                return (Self.ok, Self.tokenJSON(access: "at", expires: 3600))
            }
            let n = phase.get()
            phase.set(n + 1)
            if n == 0 {
                return (Self.status(429, headers: ["Retry-After": "2"]), Data("slow down".utf8))
            }
            return (Self.ok, Data("ok".utf8))
        }
        let session = makeSession(sleeps: sleeps)
        _ = try await session.data(for: URLRequest(url: api))
        let recorded = await sleeps.values
        XCTAssertEqual(recorded.first, 2.0, "should have honored Retry-After")
    }

    func testRetriesOn5xxWithExponentialBackoff() async throws {
        let phase = LockBox<Int>(0)
        let sleeps = SleepRecorder()
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                return (Self.ok, Self.tokenJSON(access: "at", expires: 3600))
            }
            let n = phase.get()
            phase.set(n + 1)
            if n < 2 { return (Self.status(503), Data()) }
            return (Self.ok, Data("eventually".utf8))
        }
        let session = makeSession(sleeps: sleeps)
        let (data, _) = try await session.data(for: URLRequest(url: api))
        XCTAssertEqual(String(data: data, encoding: .utf8), "eventually")
        let recorded = await sleeps.values
        XCTAssertEqual(recorded.count, 2)
        // First backoff ~0.5s, second ~1s (with jitter). Just sanity-check
        // the ratio and bounds, not the exact value.
        XCTAssertGreaterThanOrEqual(recorded[0], 0.25)
        XCTAssertLessThanOrEqual(recorded[0], 1.0)
        XCTAssertGreaterThan(recorded[1], recorded[0])
    }

    func testGivesUpAfterMaxAttemptsOn5xx() async {
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                return (Self.ok, Self.tokenJSON(access: "at", expires: 3600))
            }
            return (Self.status(500), Data("boom".utf8))
        }
        let session = makeSession()
        do {
            _ = try await session.data(for: URLRequest(url: api))
            XCTFail("expected throw")
        } catch AuthenticatedSessionError.http(let status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testNon429_4xxIsNotRetried() async {
        let phase = LockBox<Int>(0)
        StubURLProtocol.handler = { req in
            if req.url == self.tokenURL {
                return (Self.ok, Self.tokenJSON(access: "at", expires: 3600))
            }
            phase.set(phase.get() + 1)
            return (Self.status(404), Data("nope".utf8))
        }
        let session = makeSession()
        do {
            _ = try await session.data(for: URLRequest(url: api))
            XCTFail("expected throw")
        } catch AuthenticatedSessionError.http(let status, _) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(phase.get(), 1, "404 should not be retried")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - helpers

    private static let ok = HTTPURLResponse(
        url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil
    )!

    private static func status(_ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x")!, statusCode: code,
                        httpVersion: nil, headerFields: headers)!
    }

    private static func tokenJSON(access: String, expires: Int) -> Data {
        Data("""
        {"access_token":"\(access)","expires_in":\(expires),"scope":"s","token_type":"Bearer"}
        """.utf8)
    }
}

actor SleepRecorder {
    var values: [TimeInterval] = []
    func record(_ v: TimeInterval) { values.append(v) }
}
