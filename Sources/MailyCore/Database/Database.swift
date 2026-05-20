import Foundation
import GRDB

public enum DatabaseLocation {
    case inMemory
    case file(URL)

    public static var applicationSupport: DatabaseLocation {
        let fm = FileManager.default
        let base = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Maily", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return .file(base.appendingPathComponent("maily.sqlite"))
    }
}

public struct MailyDatabase {
    public let queue: DatabaseQueue

    public init(location: DatabaseLocation) throws {
        switch location {
        case .inMemory:
            self.queue = try DatabaseQueue()
        case .file(let url):
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            self.queue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try Migrations.register(in: self.queue)
    }
}
