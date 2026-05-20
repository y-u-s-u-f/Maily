import Foundation

/// Google OAuth client credentials loaded from `Secrets/oauth.json`.
///
/// The file is gitignored. `Secrets/oauth.json.example` documents the schema:
///
///     {
///       "client_id": "...apps.googleusercontent.com",
///       "client_secret": "...",
///       "redirect_uri": "http://127.0.0.1[:port]/oauth/callback"
///     }
public struct OAuthConfig: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String
    public let redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    public enum LoadError: Error, Equatable {
        /// The file still contains the placeholder values from `oauth.json.example`.
        case placeholderCredentials
    }

    private struct JSONShape: Decodable {
        let client_id: String
        let client_secret: String
        let redirect_uri: String
    }

    public static func load(from url: URL) throws -> OAuthConfig {
        let data = try Data(contentsOf: url)
        let shape = try JSONDecoder().decode(JSONShape.self, from: data)

        if shape.client_id.hasPrefix("YOUR-") || shape.client_secret.hasPrefix("YOUR-") {
            throw LoadError.placeholderCredentials
        }

        return OAuthConfig(
            clientID: shape.client_id,
            clientSecret: shape.client_secret,
            redirectURI: shape.redirect_uri
        )
    }

    /// Port explicitly specified in the redirect URI, or `nil` to let the OS
    /// pick a free port at bind time.
    public var redirectPort: Int? {
        URLComponents(string: redirectURI)?.port
    }

    /// Path portion of the redirect URI (e.g. `/oauth/callback`).
    public var redirectPath: String {
        URLComponents(string: redirectURI)?.path ?? "/"
    }
}
