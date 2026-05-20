import Foundation

/// Wraps `GET users.getProfile`.
extension GmailClient {

    public func getProfile() async throws -> ProfileResponse {
        try await getJSON("profile", queryItems: [])
    }
}

public struct ProfileResponse: Decodable, Equatable, Sendable {
    public let emailAddress: String?
    public let messagesTotal: Int?
    public let threadsTotal: Int?
    public let historyId: String?

    public init(
        emailAddress: String? = nil,
        messagesTotal: Int? = nil,
        threadsTotal: Int? = nil,
        historyId: String? = nil
    ) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }
}
