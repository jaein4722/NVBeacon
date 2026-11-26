import Foundation
import UserNotifications

@MainActor
struct ProcessExitNotificationManager {
    var isSupportedEnvironment: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? {
        guard isSupportedEnvironment else { return nil }
        return UNUserNotificationCenter.current()
    }

    func authorizationStatus() async -> NotificationPermissionState {
        guard let center else { return .unsupported }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        guard let center else { return false }
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

    func requestAuthorization() async -> NotificationPermissionState {
        guard let center else { return .unsupported }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            return granted ? .authorized : .denied
        @unknown default:
            return .denied
        }
    }

    func sendExitNotification(for watch: ProcessExitWatch) async -> Bool {
        guard let center else { return false }
        let language = AppLocalizer.currentLanguage()

        let content = UNMutableNotificationContent()
        content.title = language.text("%@ finished", watch.displayProcessName)
        content.body = watch.subtitle(language: language)
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "nvbeacon.process-exit.\(watch.id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func sendIdleNotification(for watch: GPUIdleWatch, idleDurationSeconds: Int, memoryUsedMB: Int) async -> Bool {
        guard let center else { return false }
        let language = AppLocalizer.currentLanguage()

        let content = UNMutableNotificationContent()
        content.title = language.text("%@ is idle", watch.title)
        content.body = [
            watch.connectionLabel,
            watch.gpuName,
            language.text("Idle %@s", idleDurationSeconds),
            language.text("Mem %@ MB", memoryUsedMB)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "nvbeacon.gpu-idle.\(watch.id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func sendTestNotification() async -> Bool {
        guard let center else { return false }
        let language = AppLocalizer.currentLanguage()

        let content = UNMutableNotificationContent()
        content.title = language.text("NVBeacon test notification")
        content.body = language.text("Process exit and GPU idle alerts are working normally.")
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "nvbeacon.test.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
