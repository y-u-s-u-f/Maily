import XCTest
import Network
@testable import MailyCore

final class LoopbackListenerTests: XCTestCase {

    func testReceivesCodeAndStateFromQueryString() async throws {
        let listener = try LoopbackListener(expectedPath: "/oauth/callback")
        let resultTask = Task { try await listener.waitForRedirect() }

        // Give NWListener a beat to actually be listening on the port.
        try await Task.sleep(nanoseconds: 100_000_000)

        try await sendGET(
            host: "127.0.0.1",
            port: listener.boundPort,
            path: "/oauth/callback?code=auth-code&state=xyz"
        )

        let result = try await resultTask.value
        XCTAssertEqual(result.code, "auth-code")
        XCTAssertEqual(result.state, "xyz")
    }

    func testWaitForRedirectThrowsOnOAuthError() async throws {
        let listener = try LoopbackListener(expectedPath: "/oauth/callback")
        let resultTask = Task { try await listener.waitForRedirect() }
        try await Task.sleep(nanoseconds: 100_000_000)

        try await sendGET(
            host: "127.0.0.1",
            port: listener.boundPort,
            path: "/oauth/callback?error=access_denied&state=s"
        )

        do {
            _ = try await resultTask.value
            XCTFail("expected throw")
        } catch let error as LoopbackListenerError {
            guard case .userDeniedOrError(let code) = error else {
                return XCTFail("expected .userDeniedOrError, got \(error)")
            }
            XCTAssertEqual(code, "access_denied")
        }
    }

    func testIgnoresRequestsToOtherPaths() async throws {
        let listener = try LoopbackListener(expectedPath: "/oauth/callback")
        let resultTask = Task { try await listener.waitForRedirect() }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Stray probe — should be 404'd and ignored.
        try await sendGET(host: "127.0.0.1", port: listener.boundPort, path: "/favicon.ico")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Real callback eventually arrives.
        try await sendGET(
            host: "127.0.0.1",
            port: listener.boundPort,
            path: "/oauth/callback?code=c&state=s"
        )

        let result = try await resultTask.value
        XCTAssertEqual(result.code, "c")
    }

    // MARK: - tiny raw-socket HTTP client

    private func sendGET(host: String, port: UInt16, path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error {
                            cont.resume(throwing: error)
                            conn.cancel()
                            return
                        }
                        // Read & discard response, then close.
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                            cont.resume()
                            conn.cancel()
                        }
                    })
                case .failed(let e):
                    cont.resume(throwing: e)
                default: break
                }
            }
            conn.start(queue: .global())
        }
    }
}
