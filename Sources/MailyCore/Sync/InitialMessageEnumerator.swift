import Foundation

/// Walks Gmail's `messages.list` pages for a set of labels and collects all
/// `MessageRef` values into a flat array.
///
/// The same message ID can appear under multiple labels; deduplication is
/// intentionally left to the caller (M3-c).
public actor InitialMessageEnumerator {

    // MARK: - Progress

    /// Snapshot emitted after each page is fetched.
    ///
    /// `pageToken` is the token that was **used to fetch** this page (nil for
    /// the first page of each label, which has no prior token).
    /// `collected` is the running total across *all* labels so far, including
    /// the messages just appended from this page.
    public struct Progress: Sendable {
        public let label: String
        public let pageToken: String?
        public let collected: Int
    }

    // MARK: - Stored properties

    private let client: GmailClient
    private let labels: [String]
    private let pageSize: Int
    private let onProgress: @Sendable (Progress) -> Void

    // Resume-from-crash not in scope for v1; accountRepo/accountID held for future use.
    private let accountRepo: AccountRepository
    private let accountID: String

    // MARK: - Init

    public init(
        client: GmailClient,
        accountRepo: AccountRepository,
        accountID: String,
        labels: [String] = ["INBOX", "SENT"],
        pageSize: Int = 500,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) {
        self.client = client
        self.accountRepo = accountRepo
        self.accountID = accountID
        self.labels = labels
        self.pageSize = pageSize
        self.onProgress = onProgress
    }

    // MARK: - Public API

    /// Enumerates all pages for every label in `labels` and returns the
    /// concatenated `MessageRef` list.
    ///
    /// Results are ordered by label (first label's pages fully before the
    /// second label's pages, etc.) with no deduplication.
    public func enumerate() async throws -> [MessageRef] {
        var accumulated: [MessageRef] = []

        for label in labels {
            var nextPageToken: String?

            repeat {
                let usedToken = nextPageToken

                let response = try await client.listMessages(
                    labelIds: [label],
                    maxResults: pageSize,
                    pageToken: usedToken
                )

                accumulated.append(contentsOf: response.messages ?? [])
                nextPageToken = response.nextPageToken

                onProgress(Progress(
                    label: label,
                    pageToken: usedToken,
                    collected: accumulated.count
                ))
            } while nextPageToken != nil
        }

        return accumulated
    }
}
