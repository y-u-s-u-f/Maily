import Foundation

public enum AuthenticatedSessionError: Error, Equatable {
    /// Refresh token is no longer valid. UI should kick off a fresh OAuth flow.
    case needsReauth
    /// Non-retryable HTTP failure surfaced to the caller. `data` holds the
    /// raw body for diagnostics.
    case http(status: Int, body: Data)
    case invalidResponse
    /// No refresh token stored for this account.
    case missingRefreshToken
}

public struct TokenCache: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    func isFresh(now: Date = Date()) -> Bool {
        expiresAt > now
    }
}

/// Wraps an `URLSession` for authenticated Gmail API calls.
///
/// - Injects `Authorization: Bearer <access token>`.
/// - Refreshes the access token before it expires, using the long-lived
///   refresh token loaded from the `TokenStore`.
/// - On a 401 it refreshes once and retries. A second 401 surfaces as
///   `.needsReauth` so the UI can re-run the OAuth flow.
/// - On 429 it honors `Retry-After`; on 5xx it backs off exponentially with
///   jitter. Both cap at 5 attempts.
/// - Other non-2xx responses surface as `.http(status:body:)` for the caller
///   to handle.
///
/// All Gmail endpoint wrappers (M2e) go through this — they assume the
/// auth header is taken care of and that transient failures have been
/// retried.
public actor AuthenticatedSession {

    public let account: String

    private let tokenStore: any TokenStore
    private let tokenEndpoint: TokenEndpoint
    private let session: URLSession
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let maxAttempts: Int
    private let baseBackoff: TimeInterval

    private var cachedToken: TokenCache?
    public private(set) var needsReauthFlag: Bool = false

    public init(
        account: String,
        tokenStore: any TokenStore,
        tokenEndpoint: TokenEndpoint,
        session: URLSession = .shared,
        cachedToken: TokenCache? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        maxAttempts: Int = 5,
        baseBackoff: TimeInterval = 0.5
    ) {
        self.account = account
        self.tokenStore = tokenStore
        self.tokenEndpoint = tokenEndpoint
        self.session = session
        self.cachedToken = cachedToken
        self.sleeper = sleeper
        self.maxAttempts = maxAttempts
        self.baseBackoff = baseBackoff
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var refreshedThisCall = false

        while true {
            attempt += 1
            let token = try await currentAccessToken()
            var req = request
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AuthenticatedSessionError.invalidResponse
            }

            switch http.statusCode {
            case 200..<300:
                return (data, http)

            case 401:
                if refreshedThisCall {
                    needsReauthFlag = true
                    throw AuthenticatedSessionError.needsReauth
                }
                cachedToken = nil
                refreshedThisCall = true
                continue

            case 429:
                let wait = Self.retryAfter(http) ?? backoff(attempt: attempt)
                if attempt >= maxAttempts {
                    throw AuthenticatedSessionError.http(status: 429, body: data)
                }
                await sleeper(wait)
                continue

            case 500..<600:
                if attempt >= maxAttempts {
                    throw AuthenticatedSessionError.http(status: http.statusCode, body: data)
                }
                await sleeper(backoff(attempt: attempt))
                continue

            default:
                throw AuthenticatedSessionError.http(status: http.statusCode, body: data)
            }
        }
    }

    // MARK: - token management

    private func currentAccessToken() async throws -> String {
        if let cached = cachedToken, cached.isFresh() {
            return cached.accessToken
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = try tokenStore.loadRefreshToken(account: account) else {
            throw AuthenticatedSessionError.missingRefreshToken
        }

        do {
            let response = try await tokenEndpoint.refresh(refreshToken: refreshToken)
            // Google may rotate the refresh token; if so, persist the new one.
            if let newRefresh = response.refreshToken, newRefresh != refreshToken {
                try tokenStore.saveRefreshToken(newRefresh, account: account)
            }
            let cache = TokenCache(
                accessToken: response.accessToken,
                expiresAt: response.expiresAt()
            )
            cachedToken = cache
            return cache.accessToken
        } catch TokenEndpointError.oauthError(let code, _, _) where code == "invalid_grant" {
            needsReauthFlag = true
            throw AuthenticatedSessionError.needsReauth
        }
    }

    // MARK: - backoff

    private func backoff(attempt: Int) -> TimeInterval {
        // 0.5, 1, 2, 4, 8 ... with 0.5x-1.5x multiplicative jitter.
        let base = baseBackoff * pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0.5...1.5)
        return base * jitter
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        // HTTP-date form. Skip — rare for Google APIs and not worth wiring
        // the formatter in v1.
        return nil
    }
}
