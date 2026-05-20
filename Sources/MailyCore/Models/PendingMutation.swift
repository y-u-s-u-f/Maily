import Foundation
import GRDB

public enum MutationKind: String, Codable {
    case modifyLabels
    case trash
    case untrash
    case send
    case markRead
}

public struct PendingMutation: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: String
    public var kindRaw: String
    public var payloadJson: String
    public var createdAt: Date
    public var attempts: Int
    public var lastError: String?

    public static let databaseTableName = "pending_mutations"

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case kindRaw = "kind"
        case payloadJson = "payload_json"
        case createdAt = "created_at"
        case attempts
        case lastError = "last_error"
    }

    public var kind: MutationKind {
        get { MutationKind(rawValue: kindRaw) ?? .modifyLabels }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        id: Int64? = nil,
        accountId: String,
        kind: MutationKind,
        payloadJson: String,
        createdAt: Date = Date(),
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.kindRaw = kind.rawValue
        self.payloadJson = payloadJson
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
