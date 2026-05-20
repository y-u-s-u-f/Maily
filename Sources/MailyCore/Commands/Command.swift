import Foundation

public struct Command: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let defaultShortcut: KeyboardShortcut?
    public let contextPredicate: @Sendable (CommandContext) -> Bool
    public let handler: @Sendable (CommandContext) async -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        defaultShortcut: KeyboardShortcut? = nil,
        contextPredicate: @escaping @Sendable (CommandContext) -> Bool = { _ in true },
        handler: @escaping @Sendable (CommandContext) async -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.defaultShortcut = defaultShortcut
        self.contextPredicate = contextPredicate
        self.handler = handler
    }
}
