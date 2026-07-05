import Foundation
import UserNotifications

protocol ExportNotificationScheduling {
    func prepareForExportNotifications() async
    func notifyExportCompleted(clipCount: Int, projectTitle: String) async
    func notifyExportFailed(projectTitle: String, message: String) async
}

final class ExportNotificationManager: NSObject, ExportNotificationScheduling, UNUserNotificationCenterDelegate {
    static let shared = ExportNotificationManager()

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func configure() {
        center.delegate = self
    }

    func prepareForExportNotifications() async {
        _ = await notificationsAllowed(requestIfNeeded: true)
    }

    func notifyExportCompleted(clipCount: Int, projectTitle: String) async {
        guard await notificationsAllowed(requestIfNeeded: false) else { return }

        let title = clipCount == 1 ? "Clip saved" : "\(clipCount) clips saved"
        let body = "\(projectTitle) is ready in Photos."
        await scheduleNotification(title: title, body: body, identifierPrefix: "export-complete")
    }

    func notifyExportFailed(projectTitle: String, message: String) async {
        guard await notificationsAllowed(requestIfNeeded: false) else { return }

        await scheduleNotification(
            title: "Export stopped",
            body: "\(projectTitle): \(message)",
            identifierPrefix: "export-failed"
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func notificationsAllowed(requestIfNeeded: Bool) async -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined where requestIfNeeded:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        default:
            return false
        }
    }

    private func scheduleNotification(title: String, body: String, identifierPrefix: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            return
        }
    }
}
