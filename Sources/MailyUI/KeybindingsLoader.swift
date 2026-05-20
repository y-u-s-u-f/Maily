import Foundation
import MailyCore

/// Loads user-overrideable keybindings from a JSON file and hot-reloads on change.
///
/// Errors thrown by the parser and `loadNow()` are `KeybindingsLoader.ParseError`
/// (descriptive variants for empty input, unknown modifier tokens, empty segments,
/// and multi-char keys that aren't named keys). `loadNow()` may additionally throw
/// the underlying `DecodingError` for malformed JSON.
public actor KeybindingsLoader {

    public struct Overrides: Sendable, Equatable {
        public let shortcuts: [String: KeyboardShortcut]
        public init(shortcuts: [String: KeyboardShortcut] = [:]) {
            self.shortcuts = shortcuts
        }
    }

    public enum ParseError: Error, CustomStringConvertible {
        case empty
        case emptySegment(String)
        case unknownModifier(String)
        case invalidKey(String)

        public var description: String {
            switch self {
            case .empty:
                return "Empty shortcut string"
            case .emptySegment(let s):
                return "Empty segment in shortcut: \"\(s)\""
            case .unknownModifier(let m):
                return "Unknown modifier token: \"\(m)\""
            case .invalidKey(let k):
                return "Invalid key segment: \"\(k)\""
            }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maily/keybindings.json")
    }

    private let url: URL
    private let onChange: @Sendable (Overrides) async -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var lastOverrides: Overrides = Overrides(shortcuts: [:])

    public init(
        url: URL = KeybindingsLoader.defaultURL,
        onChange: @escaping @Sendable (Overrides) async -> Void
    ) {
        self.url = url
        self.onChange = onChange
    }

    // MARK: - Public API

    public func loadNow() async throws -> Overrides {
        let overrides = try Self.loadFromDisk(url: url)
        lastOverrides = overrides
        return overrides
    }

    public func startWatching() async {
        // Re-entrancy: cancel any existing watch before starting a new one so
        // a second call doesn't leak a dispatch source or fd.
        stopWatchingInternal()
        openAndWatch()
    }

    public func stopWatching() async {
        stopWatchingInternal()
    }

    // MARK: - Parsing (exposed for tests)

    public static func parseShortcut(_ raw: String) throws -> KeyboardShortcut {
        guard !raw.isEmpty else { throw ParseError.empty }
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        for p in parts where p.isEmpty {
            throw ParseError.emptySegment(raw)
        }
        guard let last = parts.last else { throw ParseError.empty }

        var modifiers: Modifiers = []
        for token in parts.dropLast() {
            switch token.lowercased() {
            case "cmd":         modifiers.insert(.command)
            case "shift":       modifiers.insert(.shift)
            case "opt", "alt":  modifiers.insert(.option)
            case "ctrl":        modifiers.insert(.control)
            default:
                throw ParseError.unknownModifier(token)
            }
        }

        let key = try normalizeKey(last)
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }

    private static func normalizeKey(_ segment: String) throws -> String {
        switch segment.lowercased() {
        case "enter":  return "Enter"
        case "tab":    return "Tab"
        case "space":  return "Space"
        case "esc":    return "Escape"
        default:
            // Single-char keys are lowercased to match how
            // NSEvent.charactersIgnoringModifiers reports them in KeyboardRouter.
            if segment.count == 1 {
                return segment.lowercased()
            }
            throw ParseError.invalidKey(segment)
        }
    }

    // MARK: - Disk

    private struct DiskShape: Decodable {
        let shortcuts: [String: String]
    }

    private static func loadFromDisk(url: URL) throws -> Overrides {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Overrides(shortcuts: [:])
        }
        let data = try Data(contentsOf: url)
        let shape = try JSONDecoder().decode(DiskShape.self, from: data)
        var out: [String: KeyboardShortcut] = [:]
        for (id, str) in shape.shortcuts {
            out[id] = try parseShortcut(str)
        }
        return Overrides(shortcuts: out)
    }

    // MARK: - Watching

    private func openAndWatch() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — nothing to watch. Caller can retry by
            // calling startWatching() again after creating the file.
            return
        }
        self.fd = fd

        let queue = DispatchQueue(label: "maily.keybindings.watch", qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleEvent() }
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        self.source = src
        src.resume()
    }

    private func handleEvent() {
        // `.delete`/`.rename` invalidate the existing fd (atomic writes use
        // rename), so we always tear down the current source and reopen if the
        // file still exists.
        stopWatchingInternal()

        let overrides: Overrides
        do {
            overrides = try Self.loadFromDisk(url: url)
        } catch {
            FileHandle.standardError.write(
                Data("KeybindingsLoader: failed to reload \(url.path): \(error)\n".utf8)
            )
            // Re-arm the watcher on the (likely recreated) file but do not
            // notify with garbage state.
            openAndWatch()
            return
        }

        lastOverrides = overrides
        let snapshot = overrides
        let cb = onChange
        Task { await cb(snapshot) }

        openAndWatch()
    }

    private func stopWatchingInternal() {
        if let src = source {
            src.cancel() // cancel handler closes fd
            source = nil
        }
        fd = -1
    }
}
