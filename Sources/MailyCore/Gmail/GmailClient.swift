import Foundation

/// Thin transport layer over `AuthenticatedSession` for Gmail's REST API.
///
/// Each Gmail endpoint (messages.list, messages.get, history.list,
/// threads.modify, messages.send, /batch) lives in its own file as an
/// extension on `GmailClient`. This file owns only the shared URL/encoding
/// plumbing so endpoint files can be developed independently without
/// stepping on each other.
public struct GmailClient: Sendable {
    public let session: AuthenticatedSession
    public let userID: String
    public let baseURL: URL

    public init(
        session: AuthenticatedSession,
        userID: String = "me",
        baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/")!
    ) {
        self.session = session
        self.userID = userID
        self.baseURL = baseURL
    }

    /// Build `https://gmail.googleapis.com/gmail/v1/users/<userID>/<path>?...`.
    public func buildURL(_ path: String, queryItems: [URLQueryItem]) -> URL {
        let base = baseURL.appendingPathComponent("users").appendingPathComponent(userID)
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        return comps.url!
    }

    // MARK: - low-level

    @discardableResult
    public func get(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        var req = URLRequest(url: buildURL(path, queryItems: queryItems))
        req.httpMethod = "GET"
        let (data, _) = try await session.data(for: req)
        return data
    }

    @discardableResult
    public func post(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        json body: [String: Any]
    ) async throws -> Data {
        var req = URLRequest(url: buildURL(path, queryItems: queryItems))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        return data
    }

    // MARK: - typed convenience

    public func getJSON<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        let data = try await get(path, queryItems: queryItems)
        return try Self.decoder.decode(T.self, from: data)
    }

    public func postJSON<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        json body: [String: Any]
    ) async throws -> T {
        let data = try await post(path, queryItems: queryItems, json: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Gmail uses snake_case for some fields but camelCase for most. The
        // safe move is leave keys as-is and pin via CodingKeys per response.
        return d
    }()
}
