import Foundation

/// Test-only `URLProtocol` that intercepts every request a configured
/// `URLSession` makes and serves canned `(HTTPURLResponse, Data)` pairs.
///
/// Usage:
///
///     let config = URLSessionConfiguration.ephemeral
///     config.protocolClasses = [StubURLProtocol.self]
///     let session = URLSession(configuration: config)
///
///     StubURLProtocol.handler = { request in
///         (HTTPURLResponse(url: request.url!, statusCode: 200, ...)!, Data(...))
///     }
final class StubURLProtocol: URLProtocol {

    /// Set per-test. Also exposes the request to the handler so tests can
    /// assert on URL/headers/body.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Optionally record every intercepted request for later inspection.
    /// Reset in `tearDown`.
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture body — URLProtocol drops httpBody when going through
        // URLSession (it gets streamed instead), so re-read it from the stream.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            captured.httpBody = data
        }
        Self.capturedRequests.append(captured)

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    /// `URLSession` whose only protocol is `StubURLProtocol` — every request
    /// goes through the stub, none escape to the real network.
    static func stubbed() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
