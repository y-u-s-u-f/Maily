import Foundation

/// Build a multipart/mixed response body matching Gmail's `/batch/gmail/v1` shape.
/// Shared between BatchTests and MetadataBatchSyncerTests.
func makeBatchResponseBody(
    boundary: String,
    parts: [(status: Int, reason: String, headers: [(String, String)], body: String)]
) -> Data {
    var out = ""
    for part in parts {
        out += "--\(boundary)\r\n"
        out += "Content-Type: application/http\r\n"
        out += "\r\n"
        out += "HTTP/1.1 \(part.status) \(part.reason)\r\n"
        for (k, v) in part.headers {
            out += "\(k): \(v)\r\n"
        }
        out += "\r\n"
        out += part.body
        out += "\r\n"
    }
    out += "--\(boundary)--\r\n"
    return Data(out.utf8)
}

/// Stub a token endpoint hit. Returns nil when the request isn't for
/// `oauth2.googleapis.com`, so it composes with other stub handlers.
func tokenStubResponse(for req: URLRequest) -> (HTTPURLResponse, Data)? {
    guard req.url?.host == "oauth2.googleapis.com" else { return nil }
    let body = Data(#"{"access_token":"at","expires_in":3600,"scope":"s","token_type":"Bearer"}"#.utf8)
    return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
}
