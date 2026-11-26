import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable, Sendable {
    case unavailable
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .unavailable, .disabled:
            return false
        }
    }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .unavailable:
            return language.text("Unavailable", "사용 불가", "不可用")
        case .disabled:
            return language.text("Off", "꺼짐", "关闭")
        case .enabled:
            return language.text("On", "켜짐", "开启")
        case .requiresApproval:
            return language.text("Needs Approval", "승인 필요", "等待批准")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .unavailable:
            return language.text(
                "Launch at login is only available from a packaged app bundle such as NVBeacon.app.",
                "로그인 시 시작은 NVBeacon.app 같은 패키징된 앱 번들에서만 사용할 수 있습니다.",
                "打开打包好的 NVBeacon.app 后才能设置登录时启动。"
            )
        case .disabled:
            return language.text(
                "NVBeacon is not currently registered to start automatically when you log in.",
                "현재 NVBeacon은 로그인 시 자동 시작으로 등록되어 있지 않습니다.",
                "NVBeacon 当前未设为登录时启动。"
            )
        case .enabled:
            return language.text(
                "NVBeacon is registered to start automatically when you log in.",
                "로그인할 때 NVBeacon이 자동으로 시작되도록 등록되어 있습니다.",
                "NVBeacon 将在你登录时自动启动。"
            )
        case .requiresApproval:
            return language.text(
                "NVBeacon requested launch at login, but macOS still requires approval in Login Items.",
                "NVBeacon이 로그인 시 시작을 요청했지만 macOS 로그인 항목에서 추가 승인이 필요합니다.",
                "NVBeacon 已请求在登录时启动。请在 macOS 的「登录项」中批准。"
            )
        }
    }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState = .unavailable
    @Published private(set) var lastErrorMessage: String?

    var isEnabled: Bool {
        state.isEnabled
    }

    var canConfigure: Bool {
        state != .unavailable
    }

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        guard isBundledApp else {
            state = .unavailable
            return
        }

        switch SMAppService.mainApp.status {
        case .notRegistered:
            state = .disabled
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            // `notFound` is still a configurable state for a packaged app.
            // In practice it often means macOS has not registered the app in
            // Login Items yet, so treat it like "Off" instead of disabling
            // the controls entirely.
            state = .disabled
        @unknown default:
            state = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isBundledApp else {
            refreshStatus()
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        refreshStatus()
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}
