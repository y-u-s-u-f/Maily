import Foundation
import GRDB

public struct Attachment: Codable, Equatable, FetchableRecord, PersistableRecord {
    public var id: String
    public var messageId: String
    public var filename: String?
    public var mimeType: String?
    public var size: Int?
    public var gmailAttachmentId: String?
    public var localPath: String?

    public static let databaseTableName = "attachments"

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case filename
        case mimeType = "mime_type"
        case size
        case gmailAttachmentId = "gmail_attachment_id"
        case localPath = "local_path"
    }

    public init(
        id: String,
        messageId: String,
        filename: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        gmailAttachmentId: String? = nil,
        localPath: String? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.gmailAttachmentId = gmailAttachmentId
        self.localPath = localPath
    }
}
