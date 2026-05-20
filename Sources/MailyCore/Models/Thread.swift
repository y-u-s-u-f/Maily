import Foundation
import GRDB

public struct MailThread: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: String
    public var accountId: String
    public var snippet: String?
    public var subject: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int
    public var messageCount: Int
    public var labelIdsJson: String

    public static let databaseTableName = "threads"

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case snippet
        case subject
        case lastMessageAt = "last_message_at"
        case unreadCount = "unread_count"
        case messageCount = "message_count"
        case labelIdsJson = "label_ids_json"
    }

    public var labelIds: [String] {
        get { JSONStringArray.decode(labelIdsJson) }
        set { labelIdsJson = JSONStringArray.encode(newValue) }
    }

    public init(
        id: String,
        accountId: String,
        snippet: String? = nil,
        subject: String? = nil,
        lastMessageAt: Date? = nil,
        unreadCount: Int = 0,
        messageCount: Int = 0,
        labelIds: [String] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.snippet = snippet
        self.subject = subject
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.messageCount = messageCount
        self.labelIdsJson = JSONStringArray.encode(labelIds)
    }
}
