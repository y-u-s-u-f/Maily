import Foundation
import GRDB

public struct MessageFlags: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let starred = MessageFlags(rawValue: 1 << 0)
    public static let draft   = MessageFlags(rawValue: 1 << 1)
    public static let sent    = MessageFlags(rawValue: 1 << 2)
    public static let trash   = MessageFlags(rawValue: 1 << 3)
}

public struct Message: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: String
    public var threadId: String
    public var accountId: String
    public var fromAddr: String?
    public var toAddrsJson: String
    public var ccJson: String
    public var bccJson: String
    public var subject: String?
    public var snippet: String?
    public var date: Date?
    public var bodyHtml: String?
    public var bodyText: String?
    public var bodyFetchedAt: Date?
    public var labelIdsJson: String
    public var flagsRaw: Int

    public static let databaseTableName = "messages"

    enum CodingKeys: String, CodingKey {
        case id
        case threadId = "thread_id"
        case accountId = "account_id"
        case fromAddr = "from_addr"
        case toAddrsJson = "to_addrs_json"
        case ccJson = "cc_json"
        case bccJson = "bcc_json"
        case subject
        case snippet
        case date
        case bodyHtml = "body_html"
        case bodyText = "body_text"
        case bodyFetchedAt = "body_fetched_at"
        case labelIdsJson = "label_ids_json"
        case flagsRaw = "flags"
    }

    public var flags: MessageFlags {
        get { MessageFlags(rawValue: flagsRaw) }
        set { flagsRaw = newValue.rawValue }
    }

    public var toAddrs: [String] {
        get { JSONStringArray.decode(toAddrsJson) }
        set { toAddrsJson = JSONStringArray.encode(newValue) }
    }
    public var cc: [String] {
        get { JSONStringArray.decode(ccJson) }
        set { ccJson = JSONStringArray.encode(newValue) }
    }
    public var bcc: [String] {
        get { JSONStringArray.decode(bccJson) }
        set { bccJson = JSONStringArray.encode(newValue) }
    }
    public var labelIds: [String] {
        get { JSONStringArray.decode(labelIdsJson) }
        set { labelIdsJson = JSONStringArray.encode(newValue) }
    }

    public init(
        id: String,
        threadId: String,
        accountId: String,
        fromAddr: String? = nil,
        toAddrs: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String? = nil,
        snippet: String? = nil,
        date: Date? = nil,
        bodyHtml: String? = nil,
        bodyText: String? = nil,
        bodyFetchedAt: Date? = nil,
        labelIds: [String] = [],
        flags: MessageFlags = []
    ) {
        self.id = id
        self.threadId = threadId
        self.accountId = accountId
        self.fromAddr = fromAddr
        self.toAddrsJson = JSONStringArray.encode(toAddrs)
        self.ccJson = JSONStringArray.encode(cc)
        self.bccJson = JSONStringArray.encode(bcc)
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.bodyHtml = bodyHtml
        self.bodyText = bodyText
        self.bodyFetchedAt = bodyFetchedAt
        self.labelIdsJson = JSONStringArray.encode(labelIds)
        self.flagsRaw = flags.rawValue
    }
}
