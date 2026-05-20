import Foundation

public enum Focus: Sendable, Equatable {
    case sidebar
    case list
    case reading
    case compose
}

public struct CommandContext: Sendable {
    public let focus: Focus
    public let selectedThreadID: String?

    public init(focus: Focus, selectedThreadID: String? = nil) {
        self.focus = focus
        self.selectedThreadID = selectedThreadID
    }
}
