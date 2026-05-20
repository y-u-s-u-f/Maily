import Foundation
import MailyCore

@MainActor
public final class SyncStatusViewModel: ObservableObject {
    @Published public private(set) var label: String = "Idle"

    private let streamProvider: @Sendable () async -> AsyncStream<SyncEngine.Phase>
    private var didStart = false

    public init(engine: SyncEngine) {
        self.streamProvider = { await engine.phaseStream() }
    }

    internal init(phaseStream: @escaping @Sendable () async -> AsyncStream<SyncEngine.Phase>) {
        self.streamProvider = phaseStream
    }

    public func start() async {
        if didStart { return }
        didStart = true
        let stream = await streamProvider()
        for await phase in stream {
            self.label = Self.label(for: phase)
        }
    }

    internal nonisolated static func label(for phase: SyncEngine.Phase) -> String {
        switch phase {
        case .idle:
            return "Idle"
        case .enumerating:
            return "Scanning labels…"
        case .fetchingMetadata(let processed):
            return "Loading messages (\(processed))…"
        case .fetchingBodies(let processed):
            return "Loading bodies (\(processed))…"
        case .watching:
            return "Up to date"
        case .draining:
            return "Sending…"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
