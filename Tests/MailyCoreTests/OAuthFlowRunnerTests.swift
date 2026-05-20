import XCTest
import Network
import Darwin
@testable import MailyCore

final class OAuthFlowRunnerTests: XCTestCase {

    private let config = OAuthConfig(
        clientID: "client-123.apps.googleusercontent.com",
        clientSecret: "secret",
        redirectURI: "http://127.0.0.1/oauth/callback"
    )

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testHappyPathExchangesCodeAndReturnsToken() async throws {
        StubURLProtocol.handler = { _ in
            (HTTPURLResponse(url: URL(string: "x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"access_token":"at","expires_in":3599,"refresh_token":"rt","scope":"s","token_type":"Bearer"}"#.utf8))
        }
        let endpoint = TokenEndpoint(config: config, session: .stubbed())

        // Fake browser: when openURL fires, extract state + port from the
        // authorize URL and ping the loopback listener with a matching code.
        let openedURL = LockBox<URL?>(nil)
        let runner = OAuthFlowRunner(
            config: config,
            tokenEndpoint: endpoint,
            scopes: ["scope.a"],
            openURL: { url in
                openedURL.set(url)
                Self.kickLoopback(authorizeURL: url, code: "the-code", overrideState: nil)
            }
        )

        let token = try await runner.run()
        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")

        // The opened URL should be Google's authorize endpoint with our scopes.
        let comps = URLComponents(url: openedURL.get()!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "accounts.google.com")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "scope" }?.value, "scope.a")

        // The code exchange should have used the boundRedirectURI (with port).
        let body = String(data: StubURLProtocol.capturedRequests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("code=the-code"))
        // Exact percent-encoding of ':' and '/' is implementation-defined.
        // Decode then match on the canonical form.
        let decoded = body.removingPercentEncoding ?? body
        XCTAssertTrue(
            decoded.range(of: #"redirect_uri=http://127\.0\.0\.1:\d+/oauth/callback"#,
                          options: .regularExpression) != nil,
            "expected bound redirect_uri with port, got: \(body)"
        )
    }

    func testRejectsStateMismatchWithoutExchangingCode() async {
        // Token endpoint should never be hit if state validation fails.
        StubURLProtocol.handler = { _ in
            XCTFail("token endpoint must not be hit on state mismatch")
            return (HTTPURLResponse(url: URL(string: "x")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let endpoint = TokenEndpoint(config: config, session: .stubbed())

        let runner = OAuthFlowRunner(
            config: config,
            tokenEndpoint: endpoint,
            scopes: ["s"],
            openURL: { url in
                Self.kickLoopback(authorizeURL: url, code: "c", overrideState: "WRONG-STATE")
            }
        )

        do {
            _ = try await runner.run()
            XCTFail("expected throw on state mismatch")
        } catch let error as OAuthFlowError {
            XCTAssertEqual(error, .stateMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPropagatesListenerError() async {
        let endpoint = TokenEndpoint(config: config, session: .stubbed())
        let runner = OAuthFlowRunner(
            config: config,
            tokenEndpoint: endpoint,
            scopes: ["s"],
            openURL: { url in
                // Simulate user clicking "Cancel" in Google's consent screen.
                Self.kickLoopback(authorizeURL: url, code: nil, overrideState: nil, errorCode: "access_denied")
            }
        )

        do {
            _ = try await runner.run()
            XCTFail("expected throw on listener error")
        } catch let error as LoopbackListenerError {
            guard case .userDeniedOrError(let code) = error else {
                return XCTFail("expected .userDeniedOrError, got \(error)")
            }
            XCTAssertEqual(code, "access_denied")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - test helpers

    /// Parse the authorize URL we just "opened" in the fake browser, extract
    /// the bound port and state, then send a real HTTP GET to the loopback
    /// listener at that port to simulate Google's redirect.
    private static func kickLoopback(
        authorizeURL: URL,
        code: String?,
        overrideState: String?,
        errorCode: String? = nil
    ) {
        let comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let redirectURI = items["redirect_uri"]!
        let realState = items["state"]!
        let stateToSend = overrideState ?? realState

        let redirectComps = URLComponents(string: redirectURI)!
        let port = UInt16(redirectComps.port!)
        let path = redirectComps.path

        var query: [URLQueryItem] = [URLQueryItem(name: "state", value: stateToSend)]
        if let errorCode {
            query.append(URLQueryItem(name: "error", value: errorCode))
        }
        if let code {
            query.append(URLQueryItem(name: "code", value: code))
        }
        var pathComps = URLComponents()
        pathComps.path = path
        pathComps.queryItems = query
        let fullPath = pathComps.string!

        DispatchQueue.global().async {
            // Give the listener a beat to start accepting.
            usleep(100_000)
            sendGET(host: "127.0.0.1", port: port, path: fullPath)
        }
    }

    private static func sendGET(host: String, port: UInt16, path: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 { return }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress, buf.count)
        }
        // Drain a bit so the server can write its response before we close.
        var sink = [UInt8](repeating: 0, count: 1024)
        _ = sink.withUnsafeMutableBufferPointer { buf in
            read(fd, buf.baseAddress, buf.count)
        }
    }
}

/// Tiny thread-safe box for letting test closures stash a value.
final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
