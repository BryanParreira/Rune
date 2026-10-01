import AppKit
import RuneKit
import UserNotifications

/// Posts a macOS notification when a long command finishes while you're looking elsewhere.
/// Permission is requested the first time one is worth sending, not at launch. Clicking the
/// notification brings back the tab and pane that ran the command.
final class CommandNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CommandNotifier()
    private static let sessionKey = "sessionID"

    /// Called with the session to reveal when a notification is clicked.
    var onOpen: ((UUID) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
    }

    /// A plain notification (no session to reveal), e.g. a watched command's output changed.
    func post(title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
        content.sound = .default
        deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func deliver(_ request: UNNotificationRequest) {
        let center = center
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .authorized, .provisional:
                center.add(request)
            default:
                break
            }
        }
    }

    func commandFinished(command: String, exitCode: Int32?, duration: TimeInterval, sessionID: UUID) {
        let content = UNMutableNotificationContent()
        let failed = exitCode.map { $0 != 0 && !Block.nonFailureExitCodes.contains($0) } ?? false
        content.title = failed ? "Command failed" : "Command finished"
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = (trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed)
        var details = [Self.format(duration)]
        if failed, let exitCode { details.append("exit \(exitCode)") }
        content.subtitle = details.joined(separator: " · ")
        content.sound = .default
        content.userInfo = [Self.sessionKey: sessionID.uuidString]
        deliver(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Rune is in front but the command's tab isn't visible: still show the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo[Self.sessionKey] as? String
        DispatchQueue.main.async { [weak self] in
            if let raw, let id = UUID(uuidString: raw) { self?.onOpen?(id) }
            NSApp.activate()
            completionHandler()
        }
    }
}
