import Foundation
import AppKit
import UserNotifications

/// 通知包裝:UNUserNotificationCenter 只能在正式 .app bundle 內使用;
/// `swift run` 裸執行時降級為主控台輸出,避免直接崩潰。
enum Notifier {
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else {
            NSLog("AIPetUsage notification: %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
