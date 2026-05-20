import Foundation

public struct BatchSubrequest: Sendable {
    public let method: String
    public let path: String
    public let body: Data?
    public let contentType: String?

    public init(method: String, path: String, body: Data? = nil, contentType: String? = nil) {
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
    }
}

public struct BatchSubresponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}

public enum BatchError: Error, Equatable {
    case empty
    case tooManySubrequests(Int)
    case missingBoundary
    case subresponseCountMismatch(expected: Int, got: Int)
    case malformedSubresponse
}

extension GmailClient {
    /// Up to 100 subrequests per call (Google's limit). Order of response
    /// elements matches order of `subrequests`.
    public func batch(_ subrequests: [BatchSubrequest]) async throws -> [BatchSubresponse] {
        if subrequests.isEmpty { throw BatchError.empty }
        if subrequests.count > 100 { throw BatchError.tooManySubrequests(subrequests.count) }

        let boundary = "maily-batch-\(UUID().uuidString)"
        let body = Self.encodeBatchBody(subrequests, boundary: boundary)

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!)
        req.httpMethod = "POST"
        req.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let respCT = response.value(forHTTPHeaderField: "Content-Type"),
              let respBoundary = Self.parseBoundary(from: respCT)
        else {
            throw BatchError.missingBoundary
        }

        let parsed = try Self.decodeBatchBody(data, boundary: respBoundary)
        if parsed.count != subrequests.count {
            throw BatchError.subresponseCountMismatch(expected: subrequests.count, got: parsed.count)
        }
        return parsed
    }

    // MARK: - encoding

    static func encodeBatchBody(_ subrequests: [BatchSubrequest], boundary: String) -> Data {
        var out = Data()
        for (i, sub) in subrequests.enumerated() {
            out.append(Data("--\(boundary)\r\n".utf8))
            out.append(Data("Content-Type: application/http\r\n".utf8))
            out.append(Data("Content-ID: <item\(i + 1)>\r\n".utf8))
            out.append(Data("\r\n".utf8))

            out.append(Data("\(sub.method) \(sub.path) HTTP/1.1\r\n".utf8))
            if let body = sub.body {
                if let ct = sub.contentType {
                    out.append(Data("Content-Type: \(ct)\r\n".utf8))
                }
                out.append(Data("Content-Length: \(body.count)\r\n".utf8))
                out.append(Data("\r\n".utf8))
                out.append(body)
            } else {
                out.append(Data("\r\n".utf8))
            }
            out.append(Data("\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    // MARK: - response parsing

    /// Pull the `boundary=...` parameter out of a `Content-Type` header value.
    /// Tolerates quoted values and trailing parameters.
    static func parseBoundary(from contentType: String) -> String? {
        // Split on `;` and find a parameter starting with `boundary=`.
        let parts = contentType.split(separator: ";")
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.lowercased().hasPrefix("boundary=") {
                var v = String(p.dropFirst("boundary=".count))
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func decodeBatchBody(_ data: Data, boundary: String) throws -> [BatchSubresponse] {
        // Split on `--boundary`. The first chunk is the preamble (usually
        // empty); the last is the closing `--` followed by epilogue.
        let delim = Data("--\(boundary)".utf8)
        let chunks = data.split(separator: delim)

        var results: [BatchSubresponse] = []
        for chunk in chunks {
            // Skip the closing delimiter chunk, which starts with `--`.
            if chunk.prefix(2) == Data("--".utf8) { continue }
            // Strip leading CRLF (after the boundary marker) and trailing CRLF
            // (before the next boundary).
            var part = chunk
            part = Self.stripLeadingCRLF(part)
            part = Self.stripTrailingCRLF(part)
            if part.isEmpty { continue }

            let sub = try Self.parsePart(part)
            results.append(sub)
        }
        return results
    }

    /// Each part is: outer headers, blank line, embedded HTTP response
    /// (status line, headers, blank line, body).
    private static func parsePart(_ part: Data) throws -> BatchSubresponse {
        guard let outerSplit = Self.splitOnBlankLine(part) else {
            throw BatchError.malformedSubresponse
        }
        let embedded = outerSplit.after

        // Split embedded HTTP response into header block and body.
        guard let embeddedSplit = Self.splitOnBlankLine(embedded) else {
            // Some responses may have no body — accept header block alone.
            return try Self.parseEmbeddedHeadersOnly(embedded)
        }
        let headerBlock = embeddedSplit.before
        let body = embeddedSplit.after

        let (status, headers) = try Self.parseStatusAndHeaders(headerBlock)
        return BatchSubresponse(status: status, headers: headers, body: body)
    }

    private static func parseEmbeddedHeadersOnly(_ data: Data) throws -> BatchSubresponse {
        let (status, headers) = try Self.parseStatusAndHeaders(data)
        return BatchSubresponse(status: status, headers: headers, body: Data())
    }

    private static func parseStatusAndHeaders(_ data: Data) throws -> (Int, [String: String]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BatchError.malformedSubresponse
        }
        // Tolerate either CRLF or LF line endings in the embedded response.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { throw BatchError.malformedSubresponse }

        // Status line: "HTTP/1.1 200 OK"
        let pieces = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard pieces.count >= 2, let status = Int(pieces[1]) else {
            throw BatchError.malformedSubresponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (status, headers)
    }

    // MARK: - byte helpers

    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let lflf = Data("\n\n".utf8)
    private static let crlf = Data("\r\n".utf8)
    private static let lf = Data("\n".utf8)

    /// Split a byte buffer on the first blank line (CRLFCRLF or LFLF).
    /// Returns the bytes before and after the blank line (exclusive).
    private static func splitOnBlankLine(_ data: Data) -> (before: Data, after: Data)? {
        if let r = data.range(of: crlfcrlf) {
            return (data.subdata(in: data.startIndex..<r.lowerBound),
                    data.subdata(in: r.upperBound..<data.endIndex))
        }
        if let r = data.range(of: lflf) {
            return (data.subdata(in: data.startIndex..<r.lowerBound),
                    data.subdata(in: r.upperBound..<data.endIndex))
        }
        return nil
    }

    private static func stripLeadingCRLF(_ data: Data) -> Data {
        var d = data
        while d.first == 0x0D || d.first == 0x0A {
            d = d.dropFirst()
        }
        return d
    }

    private static func stripTrailingCRLF(_ data: Data) -> Data {
        var d = data
        while d.last == 0x0D || d.last == 0x0A {
            d = d.dropLast()
        }
        return d
    }
}
