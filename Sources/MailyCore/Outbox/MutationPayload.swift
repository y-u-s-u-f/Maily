import Foundation

/// JSON payload shapes persisted in `pending_mutations.payload_json`.
///
/// Each `MutationKind` has its own struct. They are serialized as JSON by
/// the call site that enqueues the mutation, and decoded here by
/// `MutationDrain` when it pops a row to dispatch.
///
/// Keeping these as plain `Codable` structs (one per kind) gives us
/// per-kind type safety, instead of a sum-type blob with optional fields.

public enum MutationPayload {

    public struct ModifyLabels: Codable, Equatable, Sendable {
        public let threadId: String
        public let addLabelIds: [String]
        public let removeLabelIds: [String]

        public init(threadId: String, addLabelIds: [String] = [], removeLabelIds: [String] = []) {
            self.threadId = threadId
            self.addLabelIds = addLabelIds
            self.removeLabelIds = removeLabelIds
        }
    }

    /// Used by `trash`, `untrash`, and `markRead` kinds — all three are
    /// thread-scoped label tweaks whose label sets are fixed by the kind
    /// itself, so the only thing the payload needs to carry is the target.
    public struct ThreadOnly: Codable, Equatable, Sendable {
        public let threadId: String

        public init(threadId: String) {
            self.threadId = threadId
        }
    }

    public struct Send: Codable, Equatable, Sendable {
        public let from: String
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]
        public let subject: String
        public let body: String
        public let inReplyTo: String?
        public let references: [String]?
        public let threadId: String?

        public init(
            from: String,
            to: [String] = [],
            cc: [String] = [],
            bcc: [String] = [],
            subject: String,
            body: String,
            inReplyTo: String? = nil,
            references: [String]? = nil,
            threadId: String? = nil
        ) {
            self.from = from
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = subject
            self.body = body
            self.inReplyTo = inReplyTo
            self.references = references
            self.threadId = threadId
        }

        public var outgoingMessage: OutgoingMessage {
            OutgoingMessage(
                from: from,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body,
                inReplyTo: inReplyTo,
                references: references
            )
        }
    }

    // MARK: - JSON helpers

    /// Serialize a payload struct to the `payload_json` string column.
    public static func encode<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decode the `payload_json` string column back to a payload struct.
    public static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
