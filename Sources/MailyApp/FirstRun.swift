import Foundation

@MainActor
public enum FirstRun {

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case bundledResourceMissing
        public var description: String {
            switch self {
            case .bundledResourceMissing:
                return "Bundled keybindings.default.json missing from MailyApp resources"
            }
        }
    }

    /// If `~/Library/Application Support/Maily/keybindings.json` doesn't exist,
    /// create it from the bundled default. Idempotent: existing file is left
    /// untouched.
    public static func ensureKeybindingsFile() throws {
        try ensureKeybindingsFile(
            destination: defaultDestination(),
            bundledSource: bundledDefaultURL()
        )
    }

    // Internal seam for tests.
    static func ensureKeybindingsFile(destination: URL, bundledSource: URL?) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return }
        guard let src = bundledSource else { throw Error.bundledResourceMissing }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: destination)
    }

    private static func defaultDestination() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maily/keybindings.json")
    }

    /// Exposed for tests: the URL of the bundled default keybindings file.
    static func bundledDefaultURL() -> URL? {
        Bundle.module.url(forResource: "keybindings.default", withExtension: "json")
    }
}
