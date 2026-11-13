import Foundation
@preconcurrency import UserNotifications

@MainActor
enum Notifier {
    private static var prepared = false
    /// 通知授权结果，设置页要据此提示用户
    static var authorizationStatus: UNAuthorizationStatus = .notDetermined

    static func prepare(requestIfMissing: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                authorizationStatus = status
                if requestIfMissing, status == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        _ = granted
                    }
                }
            }
        }
        prepared = true
    }

    static var isReady: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    static func post(title: String, body: String, id: String) {
        if !prepared { prepare() }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
