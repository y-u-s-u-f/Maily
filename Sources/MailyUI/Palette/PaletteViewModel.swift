// Drives the command palette overlay. Owns the live query string, current
// context, the fuzzy-search results, and the selected row index.
//
// Threading: bound to @MainActor because callers are SwiftUI views and the
// underlying CommandRegistry is an `actor` whose API is async. We therefore
// recompute results asynchronously off `query`/context changes and expose
// `recomputeNow()` for tests to deterministically await.
import Foundation
import MailyCore

@MainActor
public final class PaletteViewModel: ObservableObject {
    public static let resultCap = 50

    @Published public var query: String = "" {
        didSet {
            // Any query change resets the highlighted row so the user always
            // starts from the top of the freshly filtered list.
            selectedIndex = 0
            scheduleRecompute()
        }
    }
    @Published public private(set) var results: [Command] = []
    @Published public var selectedIndex: Int = 0

    private let registry: CommandRegistry
    private var context: CommandContext
    private var recomputeTask: Task<Void, Never>?

    public init(registry: CommandRegistry, context: CommandContext) {
        self.registry = registry
        self.context = context
        scheduleRecompute()
    }

    public func updateContext(_ context: CommandContext) {
        self.context = context
        selectedIndex = 0
        scheduleRecompute()
    }

    /// Move the selection by `delta` rows, wrapping around the bounds.
    /// No-op (and leaves `selectedIndex == 0`) when there are no results.
    public func moveSelection(_ delta: Int) {
        guard !results.isEmpty else {
            selectedIndex = 0
            return
        }
        let count = results.count
        // Swift's `%` can return a negative value for a negative dividend, so
        // we offset into positive territory before taking the modulo.
        let raw = selectedIndex + delta
        let wrapped = ((raw % count) + count) % count
        selectedIndex = wrapped
    }

    /// Dispatch the currently-highlighted command. No-op if results are empty.
    public func activateSelected() async {
        guard !results.isEmpty, results.indices.contains(selectedIndex) else { return }
        let command = results[selectedIndex]
        let ctx = context
        await command.handler(ctx)
    }

    /// Forces a synchronous-from-the-caller's-perspective recompute. Tests
    /// call this to avoid racing the `didSet`-spawned Task.
    public func recomputeNow() async {
        recomputeTask?.cancel()
        let query = self.query
        let context = self.context
        let registry = self.registry
        let fetched = await registry.search(query, context: context)
        let capped = Array(fetched.prefix(Self.resultCap))
        self.results = capped
        if selectedIndex >= capped.count {
            selectedIndex = 0
        }
    }

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            await self?.recomputeNow()
        }
    }
}
