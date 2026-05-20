import Foundation

public enum OAuthFlowError: Error, Equatable {
    /// The `state` parameter Google returned does not match the one we sent.
    /// Treat as hostile: somebody is replaying or forging a redirect.
    case stateMismatch
    /// `OAuthConfig.redirectURI` could not be parsed as a URL.
    case invalidRedirectURI
}

/// Orchestrates the full installed-app OAuth flow:
///
/// 1. Generate PKCE verifier + challenge + cryptographic state.
/// 2. Start a `LoopbackListener` on an ephemeral 127.0.0.1 port.
/// 3. Substitute that port into the configured redirect URI.
/// 4. Build the Google authorize URL and hand it to `openURL`
///    (production: `NSWorkspace.shared.open(_:)`).
/// 5. Wait for the loopback redirect.
/// 6. Validate state, exchange code via `TokenEndpoint`.
///
/// Callers handle persistence: the returned `TokenResponse.refreshToken`
/// is what gets written to the `TokenStore`.
public struct OAuthFlowRunner: Sendable {
    public let config: OAuthConfig
    public let tokenEndpoint: TokenEndpoint
    public let scopes: [String]
    public let openURL: @Sendable (URL) -> Void

    public init(
        config: OAuthConfig,
        tokenEndpoint: TokenEndpoint,
        scopes: [String] = OAuthFlow.defaultScopes,
        openURL: @escaping @Sendable (URL) -> Void
    ) {
        self.config = config
        self.tokenEndpoint = tokenEndpoint
        self.scopes = scopes
        self.openURL = openURL
    }

    public func run() async throws -> TokenResponse {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = OAuthFlow.generateState()

        let listener = try LoopbackListener(expectedPath: config.redirectPath)
        defer { listener.shutdown() }

        guard let boundRedirectURI = Self.boundRedirectURI(
            config: config,
            port: listener.boundPort
        ) else {
            throw OAuthFlowError.invalidRedirectURI
        }

        let authURL = OAuthFlow.authorizationURL(
            config: config,
            boundRedirectURI: boundRedirectURI,
            scopes: scopes,
            state: state,
            codeChallenge: challenge
        )

        openURL(authURL)

        let redirect = try await listener.waitForRedirect()
        guard redirect.state == state else {
            throw OAuthFlowError.stateMismatch
        }

        return try await tokenEndpoint.exchangeCode(
            redirect.code,
            codeVerifier: verifier,
            boundRedirectURI: boundRedirectURI
        )
    }

    /// Substitute the kernel-assigned port into the configured redirect URI.
    /// The configured URI's port (if any) is just for documentation — what
    /// matters is that authorize and token-exchange both send the *same*
    /// `redirect_uri` string, and that the listener is bound to that port.
    static func boundRedirectURI(config: OAuthConfig, port: UInt16) -> String? {
        var comps = URLComponents(string: config.redirectURI)
        comps?.port = Int(port)
        return comps?.string
    }
}
