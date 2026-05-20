import Foundation
import UserNotifications

/// Posts a local notification when new threads land in the inbox. Wired
/// to the SyncEngine's history-watcher path via a callback.
///
/// Minimal v1: requests authorization once on `start()`, posts a single
/// "You have new mail" notification per batch of new threads. No aggregation,
/// no per-thread payload — that's M10+.
public actor MailNotifier {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func start() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func notifyNewMail(count: Int) async {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Maily"
        content.body = count == 1 ? "You have 1 new message" : "You have \(count) new messages"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
