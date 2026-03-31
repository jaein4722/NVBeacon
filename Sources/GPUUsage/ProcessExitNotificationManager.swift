import Foundation
import UserNotifications

@MainActor
struct ProcessExitNotificationManager {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func sendExitNotification(for watch: ProcessExitWatch) async {
        let content = UNMutableNotificationContent()
        content.title = "\(watch.displayProcessName) finished"
        content.body = watch.subtitle
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "gpuusage.process-exit.\(watch.id)",
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }
}
