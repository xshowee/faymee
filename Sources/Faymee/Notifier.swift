import UserNotifications

enum Notifier {
    private static let delegate = Delegate()

    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// silent 为 true 时不带声音：转写这类不紧急的消息可能在开会时弹出，不能出声。
    /// 录音告警保持默认声音
    static func post(_ title: String, _ body: String, silent: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 菜单栏 App 打开着面板时也算前台，默认不弹横幅；录音告警必须弹出来。
    /// 是否出声按通知本身决定，否则静音通知在前台时也会响
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler(notification.request.content.sound == nil ? [.banner] : [.banner, .sound])
        }
    }
}
