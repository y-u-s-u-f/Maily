import Foundation

public enum MessageFormat: String, Sendable {
    case minimal
    case full
    case raw
    case metadata
}

public struct GmailMessage: Decodable, Equatable, Sendable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    public let internalDate: String?
    public let sizeEstimate: Int?
    public let payload: MessagePayload?

    public init(
        id: String,
        threadId: String,
        labelIds: [String]? = nil,
        snippet: String? = nil,
        historyId: String? = nil,
        internalDate: String? = nil,
        sizeEstimate: Int? = nil,
        payload: MessagePayload? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.sizeEstimate = sizeEstimate
        self.payload = payload
    }
}

public struct MessagePayload: Decodable, Equatable, Sendable {
    public let mimeType: String?
    public let filename: String?
    public let headers: [MessageHeader]?
    public let body: MessageBody?
    public let parts: [MessagePayload]?

    public init(
        mimeType: String? = nil,
        filename: String? = nil,
        headers: [MessageHeader]? = nil,
        body: MessageBody? = nil,
        parts: [MessagePayload]? = nil
    ) {
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }
}

public struct MessageHeader: Decodable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MessageBody: Decodable, Equatable, Sendable {
    public let size: Int?
    public let data: String?
    public let attachmentId: String?

    public init(size: Int? = nil, data: String? = nil, attachmentId: String? = nil) {
        self.size = size
        self.data = data
        self.attachmentId = attachmentId
    }
}

public extension GmailClient {
    func getMessage(
        id: String,
        format: MessageFormat = .full,
        metadataHeaders: [String] = []
    ) async throws -> GmailMessage {
        var items: [URLQueryItem] = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            for header in metadataHeaders {
                items.append(URLQueryItem(name: "metadataHeaders", value: header))
            }
        }
        return try await getJSON("messages/\(id)", queryItems: items)
    }
}
