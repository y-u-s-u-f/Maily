import Foundation
import Darwin

public enum LoopbackListenerError: Error, Equatable {
    case userDeniedOrError(String)
    case malformedRequest
    case listenerFailed(String)
}

public struct LoopbackRedirect: Equatable, Sendable {
    public let code: String
    public let state: String
}

/// One-shot HTTP/1.1 server bound to 127.0.0.1 on an ephemeral port. Used by
/// the OAuth flow: Google redirects the user's browser to
/// `http://127.0.0.1:<boundPort>/oauth/callback?code=...&state=...`, the
/// listener captures the query, serves a small "you can close this tab"
/// page, and cancels itself.
///
/// The listener is started in `init`. `boundPort` is available immediately
/// so the caller can substitute it into the authorize URL's `redirect_uri`.
/// `waitForRedirect()` suspends until the first request that matches
/// `expectedPath` arrives.
///
/// Built on BSD sockets directly because `NWListener(using: .tcp, on: .any)`
/// returns POSIX EINVAL on at least one macOS version we target — see commit
/// message for details.
public final class LoopbackListener: @unchecked Sendable {

    public let boundPort: UInt16
    public let expectedPath: String

    private let socketFD: Int32
    private let queue = DispatchQueue(label: "dev.yusuf.maily.LoopbackListener")
    private let acceptSource: DispatchSourceRead

    private let lock = NSLock()
    private var pendingContinuation: CheckedContinuation<LoopbackRedirect, Error>?
    private var resolved = false
    private var shutDown = false

    public init(expectedPath: String = "/oauth/callback") throws {
        self.expectedPath = expectedPath

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw LoopbackListenerError.listenerFailed("socket() failed: errno \(errno)")
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            let e = errno
            close(fd)
            throw LoopbackListenerError.listenerFailed("bind() failed: errno \(e)")
        }

        if listen(fd, 4) != 0 {
            let e = errno
            close(fd)
            throw LoopbackListenerError.listenerFailed("listen() failed: errno \(e)")
        }

        // Read back the actual port the kernel chose.
        var assigned = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(fd, saPtr, &addrLen)
            }
        }
        if nameResult != 0 {
            let e = errno
            close(fd)
            throw LoopbackListenerError.listenerFailed("getsockname() failed: errno \(e)")
        }
        let port = UInt16(bigEndian: assigned.sin_port)

        self.socketFD = fd
        self.boundPort = port

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.acceptSource = src
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { close(fd) }
        src.resume()
    }

    deinit {
        shutdown()
    }

    public func waitForRedirect() async throws -> LoopbackRedirect {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if resolved {
                lock.unlock()
                cont.resume(throwing: LoopbackListenerError.listenerFailed("already resolved"))
                return
            }
            pendingContinuation = cont
            lock.unlock()
        }
    }

    /// Stop accepting new connections. Safe to call multiple times.
    public func shutdown() {
        lock.lock()
        let wasDown = shutDown
        shutDown = true
        lock.unlock()
        if !wasDown {
            acceptSource.cancel()
        }
    }

    // MARK: - accept loop

    private func acceptOne() {
        var clientAddr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = accept(socketFD, &clientAddr, &len)
        if clientFD < 0 { return }
        queue.async { [weak self] in self?.handle(clientFD: clientFD) }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }

        // Read request — small, headers-only.
        var buffer = Data()
        let chunkSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buf.deallocate() }

        while buffer.count < 64 * 1024 {
            let n = read(clientFD, buf, chunkSize)
            if n <= 0 { break }
            buffer.append(buf, count: n)
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        guard let headersEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            respond(clientFD, status: "400 Bad Request", body: "Bad request")
            return
        }
        let headers = buffer.subdata(in: 0..<headersEnd.lowerBound)
        processRequest(headers, on: clientFD)
    }

    private func processRequest(_ headers: Data, on clientFD: Int32) {
        guard let requestLine = String(data: headers, encoding: .utf8)?
            .split(separator: "\r\n").first.map(String.init)
        else {
            respond(clientFD, status: "400 Bad Request", body: "Bad request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(clientFD, status: "405 Method Not Allowed", body: "GET only")
            return
        }
        let target = String(parts[1])

        guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            respond(clientFD, status: "400 Bad Request", body: "Bad target")
            return
        }
        guard comps.path == expectedPath else {
            respond(clientFD, status: "404 Not Found", body: "Not found")
            return
        }

        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if let errorCode = items["error"] {
            respond(clientFD, status: "200 OK", body: Self.errorHTML(errorCode))
            resolve(.failure(LoopbackListenerError.userDeniedOrError(errorCode)))
            return
        }
        guard let code = items["code"], let state = items["state"] else {
            respond(clientFD, status: "400 Bad Request", body: "Missing code or state")
            resolve(.failure(LoopbackListenerError.malformedRequest))
            return
        }

        respond(clientFD, status: "200 OK", body: Self.successHTML)
        resolve(.success(LoopbackRedirect(code: code, state: state)))
    }

    private func respond(_ clientFD: Int32, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        let data = Array(response.utf8)
        _ = data.withUnsafeBufferPointer { ptr in
            write(clientFD, ptr.baseAddress, ptr.count)
        }
    }

    private func resolve(_ result: Result<LoopbackRedirect, Error>) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let cont = pendingContinuation
        pendingContinuation = nil
        lock.unlock()

        shutdown()

        guard let cont else { return }
        switch result {
        case .success(let r): cont.resume(returning: r)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: - HTML

    private static let successHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Maily</title>
    <style>body{font:14px -apple-system,system-ui,sans-serif;max-width:480px;margin:80px auto;padding:0 24px;color:#222;text-align:center}</style>
    </head><body><h1>You're signed in.</h1><p>You can close this tab and return to Maily.</p></body></html>
    """

    private static func errorHTML(_ code: String) -> String {
        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Maily — sign-in failed</title>
        <style>body{font:14px -apple-system,system-ui,sans-serif;max-width:480px;margin:80px auto;padding:0 24px;color:#222;text-align:center}</style>
        </head><body><h1>Sign-in failed</h1><p>Reason: <code>\(escaped)</code></p><p>You can close this tab and try again from Maily.</p></body></html>
        """
    }
}
