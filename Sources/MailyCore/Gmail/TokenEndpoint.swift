import Foundation

/// Decoded response from Google's `/token` endpoint.
public struct TokenResponse: Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
    public let scope: String
    public let tokenType: String

    /// Wall-clock instant after which `accessToken` should be considered
    /// stale. We refresh 60 s early to absorb clock skew + round-trip time.
    public func expiresAt(now: Date = Date(), skew: TimeInterval = 60) -> Date {
        now.addingTimeInterval(TimeInterval(expiresIn) - skew)
    }
}

public enum TokenEndpointError: Error, Equatable, Sendable {
    /// Non-2xx response with a parseable OAuth error envelope.
    case oauthError(code: String, description: String?, status: Int)
    /// Non-2xx response without a recognized error body.
    case http(status: Int, body: String)
    case invalidResponse
}

/// HTTP wrapper around https://oauth2.googleapis.com/token.
///
/// Two flows: `exchangeCode` (turns an authorization code into the first pair
/// of tokens) and `refresh` (uses a long-lived refresh token to mint a new
/// access token). The PKCE verifier passed to `exchangeCode` must be the
/// same string whose SHA-256 was sent as `code_challenge` in the auth URL.
public struct TokenEndpoint: Sendable {
    public let config: OAuthConfig
    public let session: URLSession
    public let endpointURL: URL

    public init(
        config: OAuthConfig,
        session: URLSession = .shared,
        endpointURL: URL = URL(string: "https://oauth2.googleapis.com/token")!
    ) {
        self.config = config
        self.session = session
        self.endpointURL = endpointURL
    }

    public func exchangeCode(
        _ code: String,
        codeVerifier: String,
        boundRedirectURI: String
    ) async throws -> TokenResponse {
        try await post(form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": boundRedirectURI,
        ])
    }

    public func refresh(refreshToken: String) async throws -> TokenResponse {
        try await post(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
        ])
    }

    // MARK: - private

    private func post(form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncoded(form).utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TokenEndpointError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            return try decodeSuccess(data)
        }

        // Try the standard OAuth error envelope first; otherwise raw body.
        if let errBody = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            throw TokenEndpointError.oauthError(
                code: errBody.error,
                description: errBody.error_description,
                status: http.statusCode
            )
        }
        throw TokenEndpointError.http(
            status: http.statusCode,
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func decodeSuccess(_ data: Data) throws -> TokenResponse {
        let shape = try JSONDecoder().decode(SuccessShape.self, from: data)
        return TokenResponse(
            accessToken: shape.access_token,
            expiresIn: shape.expires_in,
            refreshToken: shape.refresh_token,
            scope: shape.scope ?? "",
            tokenType: shape.token_type
        )
    }

    private static func formEncoded(_ params: [String: String]) -> String {
        // Sort for deterministic ordering — keeps tests stable.
        var allowed = CharacterSet.urlQueryAllowed
        // Per RFC 3986 these are reserved in application/x-www-form-urlencoded
        // bodies even though urlQueryAllowed permits them.
        allowed.remove(charactersIn: "+&=")
        return params
            .sorted { $0.key < $1.key }
            .map { (k, v) in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
    }

    private struct SuccessShape: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
        let token_type: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: String
        let error_description: String?
    }
}
