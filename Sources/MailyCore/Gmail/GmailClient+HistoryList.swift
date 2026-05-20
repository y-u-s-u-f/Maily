import Foundation

/// `users.history.list` — incremental sync since a known `historyId`.
///
/// Note: a `404` here means `startHistoryId` has expired (Gmail retains
/// ~7 days of history). This surfaces as
/// `AuthenticatedSessionError.http(status: 404, ...)`; callers (SyncEngine)
/// should treat that as a signal to fall back to a full re-list.
extension GmailClient {

    public func listHistory(
        startHistoryId: String,
        labelId: String? = nil,
        historyTypes: [String] = [],
        pageToken: String? = nil,
        maxResults: Int? = nil
    ) async throws -> HistoryListResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId)
        ]
        if let labelId {
            items.append(URLQueryItem(name: "labelId", value: labelId))
        }
        for type in historyTypes {
            items.append(URLQueryItem(name: "historyTypes", value: type))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let maxResults {
            items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        }
        return try await getJSON("history", queryItems: items)
    }
}

public struct HistoryMessageRef: Decodable, Equatable, Sendable {
    public let id: String
    public let threadId: String

    public init(id: String, threadId: String) {
        self.id = id
        self.threadId = threadId
    }
}

public struct HistoryMessageMutation: Decodable, Equatable, Sendable {
    public let message: HistoryMessageRef
    public let labelIds: [String]?

    public init(message: HistoryMessageRef, labelIds: [String]? = nil) {
        self.message = message
        self.labelIds = labelIds
    }
}

public struct HistoryEntry: Decodable, Equatable, Sendable {
    public let id: String
    public let messages: [HistoryMessageRef]?
    public let messagesAdded: [HistoryMessageMutation]?
    public let messagesDeleted: [HistoryMessageMutation]?
    public let labelsAdded: [HistoryMessageMutation]?
    public let labelsRemoved: [HistoryMessageMutation]?

    public init(
        id: String,
        messages: [HistoryMessageRef]? = nil,
        messagesAdded: [HistoryMessageMutation]? = nil,
        messagesDeleted: [HistoryMessageMutation]? = nil,
        labelsAdded: [HistoryMessageMutation]? = nil,
        labelsRemoved: [HistoryMessageMutation]? = nil
    ) {
        self.id = id
        self.messages = messages
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }
}

public struct HistoryListResponse: Decodable, Equatable, Sendable {
    public let history: [HistoryEntry]?
    public let nextPageToken: String?
    public let historyId: String?

    public init(
        history: [HistoryEntry]? = nil,
        nextPageToken: String? = nil,
        historyId: String? = nil
    ) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
}
