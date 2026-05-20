import Foundation

public struct ThreadMessageRef: Decodable, Equatable, Sendable {
    public let id: String
    public let threadId: String

    public init(id: String, threadId: String) {
        self.id = id
        self.threadId = threadId
    }
}

public struct GmailThread: Decodable, Equatable, Sendable {
    public let id: String
    public let snippet: String?
    public let historyId: String?
    public let messages: [ThreadMessageRef]?

    public init(
        id: String,
        snippet: String? = nil,
        historyId: String? = nil,
        messages: [ThreadMessageRef]? = nil
    ) {
        self.id = id
        self.snippet = snippet
        self.historyId = historyId
        self.messages = messages
    }
}

extension GmailClient {
    public func modifyThread(
        id: String,
        addLabelIds: [String] = [],
        removeLabelIds: [String] = []
    ) async throws -> GmailThread {
        let path = "threads/\(id)/modify"
        let body: [String: Any] = [
            "addLabelIds": addLabelIds,
            "removeLabelIds": removeLabelIds,
        ]
        return try await postJSON(path, queryItems: [], json: body)
    }
}
