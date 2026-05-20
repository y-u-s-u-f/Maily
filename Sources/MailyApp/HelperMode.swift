import Foundation

public enum HelperMode: Equatable, Sendable {
    case normal
    case syncOnly

    /// Returns .syncOnly when argv contains "--sync-only", else .normal.
    /// argv[0] is the process name and is ignored.
    public static func parse(_ argv: [String]) -> HelperMode {
        argv.dropFirst().contains("--sync-only") ? .syncOnly : .normal
    }
}
