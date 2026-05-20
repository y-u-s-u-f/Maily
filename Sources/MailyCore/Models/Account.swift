import Foundation
import GRDB

public struct Account: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: String
    public var email: String
    public var oauthRefreshTokenRef: String?
    public var historyId: String?
    public var lastFullSyncAt: Date?

    public static let databaseTableName = "accounts"

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case oauthRefreshTokenRef = "oauth_refresh_token_ref"
        case historyId = "history_id"
        case lastFullSyncAt = "last_full_sync_at"
    }

    public init(
        id: String,
        email: String,
        oauthRefreshTokenRef: String? = nil,
        historyId: String? = nil,
        lastFullSyncAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.oauthRefreshTokenRef = oauthRefreshTokenRef
        self.historyId = historyId
        self.lastFullSyncAt = lastFullSyncAt
    }
}
