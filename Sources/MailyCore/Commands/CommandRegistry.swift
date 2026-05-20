import Foundation

public actor CommandRegistry {
    private var commands: [Command] = []

    public init() {}

    public func register(_ command: Command) {
        commands.append(command)
    }

    public func all() -> [Command] {
        commands
    }

    public func search(_ query: String, context: CommandContext) -> [Command] {
        let available = commands.filter { $0.contextPredicate(context) }
        if query.isEmpty { return available }

        let scored: [(Command, Int, Int)] = available.enumerated().compactMap { idx, cmd in
            guard let score = FuzzyMatch.bestScore(query: query, title: cmd.title, keywords: cmd.keywords) else {
                return nil
            }
            return (cmd, score, idx)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.2 < rhs.2
            }
            .map(\.0)
    }
}
