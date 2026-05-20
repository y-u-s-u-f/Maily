import Foundation
import GRDB

public struct Label: Codable, Equatable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable {
        case system
        case user
    }

    public var id: String
    public var accountId: String
    public var name: String
    public var typeRaw: String
    public var color: String?

    public static let databaseTableName = "labels"

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case name
        case typeRaw = "type"
        case color
    }

    public var kind: Kind {
        get { Kind(rawValue: typeRaw) ?? .user }
        set { typeRaw = newValue.rawValue }
    }

    public init(id: String, accountId: String, name: String, kind: Kind, color: String? = nil) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.typeRaw = kind.rawValue
        self.color = color
    }
}
