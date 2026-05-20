import Foundation

/// Wraps `GET users.messages.list`.
extension GmailClient {

    /// Lists message IDs matching the given Gmail search params.
    public func listMessages(
        q: String? = nil,
        labelIds: [String] = [],
        maxResults: Int? = nil,
        pageToken: String? = nil,
        includeSpamTrash: Bool? = nil
    ) async throws -> MessagesListResponse {
        var items: [URLQueryItem] = []
        if let q { items.append(URLQueryItem(name: "q", value: q)) }
        for id in labelIds {
            items.append(URLQueryItem(name: "labelIds", value: id))
        }
        if let maxResults {
            items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let includeSpamTrash {
            items.append(URLQueryItem(name: "includeSpamTrash", value: includeSpamTrash ? "true" : "false"))
        }
        return try await getJSON("messages", queryItems: items)
    }
}

/// Response body for `users.messages.list`.
public struct MessagesListResponse: Decodable, Equatable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    public init(messages: [MessageRef]?, nextPageToken: String?, resultSizeEstimate: Int?) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
}

/// Lightweight `(id, threadId)` pair returned by list/history endpoints.
public struct MessageRef: Decodable, Equatable, Sendable {
    public let id: String
    public let threadId: String

    public init(id: String, threadId: String) {
        self.id = id
        self.threadId = threadId
    }
}
