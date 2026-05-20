import Foundation
import UserNotifications
import Combine
import MailyCore
// @preconcurrency silences AnyDatabaseCancellable Sendable warning. Mirrors InboxViewModel.swift.
@preconcurrency import GRDB

public protocol NotificationAuthority: Sendable {
    func requestAuth() async -> Bool
}

public protocol NotificationPoster: Sendable {
    func deliver(id: String, title: String, body: String, userInfo: [String: String]) async
}

public struct SystemNotificationAuthority: NotificationAuthority {
    public init() {}
    public func requestAuth() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

public struct SystemNotificationPoster: NotificationPoster {
    public init() {}
    public func deliver(id: String, title: String, body: String, userInfo: [String: String]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
public final class MailNotifier: NSObject {
    private let messageRepo: MessageRepository
    private let accountID: String
    private let authority: NotificationAuthority
    private let poster: NotificationPoster

    private var cancellable: AnyDatabaseCancellable?
    private var notifiedIDs: Set<String> = []
    private var hasSeededBaseline = false

    public init(
        messageRepo: MessageRepository,
        accountID: String,
        authority: NotificationAuthority = SystemNotificationAuthority(),
        poster: NotificationPoster = SystemNotificationPoster()
    ) {
        self.messageRepo = messageRepo
        self.accountID = accountID
        self.authority = authority
        self.poster = poster
        super.init()
    }

    public func start() async {
        let granted = await authority.requestAuth()
        guard granted else { return }

        // Only touch UNUserNotificationCenter.current() when we're actually
        // delivering through the system poster. In tests (or any environment
        // without a proper main bundle), accessing current() throws an
        // NSException that cannot be caught from Swift.
        if poster is SystemNotificationPoster {
            UNUserNotificationCenter.current().delegate = self
        }

        let observation = messageRepo.observeInboxUnread(accountId: accountID)
        cancellable = observation.start(
            in: messageRepo.queue,
            scheduling: .async(onQueue: .main),
            // TODO(M9): surface observation errors when notification selection is wired.
            onError: { _ in },
            onChange: { [weak self] messages in
                guard let self else { return }
                self.handleEmission(messages)
            }
        )
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
        notifiedIDs.removeAll()
        hasSeededBaseline = false
    }

    internal func _notifiedIDsForTesting() -> Set<String> {
        notifiedIDs
    }

    private func handleEmission(_ messages: [Message]) {
        if !hasSeededBaseline {
            hasSeededBaseline = true
            for m in messages { notifiedIDs.insert(m.id) }
            return
        }
        let poster = self.poster
        for m in messages where !notifiedIDs.contains(m.id) {
            notifiedIDs.insert(m.id)
            let title = m.fromAddr ?? ""
            let body = m.subject ?? ""
            let userInfo: [String: String] = ["threadID": m.threadId]
            let id = m.id
            Task { await poster.deliver(id: id, title: title, body: body, userInfo: userInfo) }
        }
    }
}

extension MailNotifier: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // TODO(M9): wire the threadID in response.notification.request.content.userInfo
        // to the inbox UI so tapping the notification selects the thread.
        completionHandler()
    }
}
