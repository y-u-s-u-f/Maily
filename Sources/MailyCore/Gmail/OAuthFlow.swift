import Foundation
import CryptoKit

/// RFC 7636 — Proof Key for Code Exchange. Used by `OAuthFlow` so the
/// authorization code returned to the loopback redirect is useless to anyone
/// who didn't initiate the flow.
public enum PKCE {

    /// Generate a 64-character random verifier from the RFC 7636 unreserved
    /// alphabet. 64 chars is comfortably inside the 43..128 valid range and
    /// gives ~380 bits of entropy.
    public static func generateVerifier() -> String {
        let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return String(bytes.map { unreserved[Int($0) % unreserved.count] })
    }

    /// S256 challenge: BASE64URL(SHA256(verifier)), no padding.
    public static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }
}

/// State + helpers for the installed-app OAuth 2.0 flow against Google
/// (RFC 8252). Pure functions only — actual HTTP and the loopback listener
/// land in later commits and call into these.
public enum OAuthFlow {

    /// Default scopes for Maily v1: read/modify mail (no send-as, no settings).
    public static let defaultScopes: [String] = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/userinfo.email",
    ]

    /// Build the URL the user is sent to in their browser. `boundRedirectURI`
    /// is the redirect URI with the actual port the loopback listener bound to
    /// substituted in — Google requires an exact match between this and what
    /// the listener will receive on.
    public static func authorizationURL(
        config: OAuthConfig,
        boundRedirectURI: String,
        scopes: [String],
        state: String,
        codeChallenge: String
    ) -> URL {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: boundRedirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // access_type=offline + prompt=consent guarantees a refresh_token
            // even on re-auth, otherwise Google omits it on subsequent grants.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps.url!
    }

    /// Cryptographically random `state` value, used to bind the redirect back
    /// to the request it came from.
    public static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64URLEncodedString()
    }
}

// MARK: - base64url helper

extension Data {
    /// Base64URL encoding without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
