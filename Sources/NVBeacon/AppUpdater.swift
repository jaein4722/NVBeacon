import Combine
import Foundation
import Sparkle

enum AppUpdaterAvailability: Equatable {
    case ready
    case requiresAppBundle
    case missingFeedURL
    case missingPublicKey

    var isAvailable: Bool {
        self == .ready
    }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .ready:
            return language.text("Ready", "준비됨", "就绪")
        case .requiresAppBundle:
            return language.text("Packaged App Required", "패키징된 앱 필요", "需要使用已打包的应用")
        case .missingFeedURL:
            return language.text("Feed URL Missing", "피드 URL 없음", "缺少更新地址")
        case .missingPublicKey:
            return language.text("Signing Key Missing", "서명 키 없음", "缺少签名密钥")
        }
    }

    func detail(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .ready:
            return language.text(
                "Sparkle is configured and can check for updates.",
                "Sparkle이 구성되어 있으며 업데이트를 확인할 수 있습니다.",
                "Sparkle 已配置，可以检查更新。"
            )
        case .requiresAppBundle:
            return language.text(
                "Updates are available only when NVBeacon runs from a packaged .app bundle.",
                "업데이트 기능은 NVBeacon이 패키징된 .app 번들로 실행될 때만 사용할 수 있습니다.",
                "请打开打包好的 NVBeacon.app 以检查更新。"
            )
        case .missingFeedURL:
            return language.text(
                "The appcast feed URL is missing from the app bundle, so update checks are disabled.",
                "앱 번들에 appcast feed URL이 없어 업데이트 확인이 비활성화되어 있습니다.",
                "应用缺少更新地址，无法检查更新。"
            )
        case .missingPublicKey:
            return language.text(
                "The Sparkle public signing key is missing from the app bundle, so secure update checks are disabled.",
                "앱 번들에 Sparkle 공개 서명 키가 없어 안전한 업데이트 확인이 비활성화되어 있습니다.",
                "应用缺少用于验证更新签名的 Sparkle 公钥，无法检查更新。"
            )
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var availability: AppUpdaterAvailability = .requiresAppBundle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var feedURL: URL?
    @Published private(set) var lastUpdateCheckDate: Date?

    private var updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    func startIfPossible() {
        guard updaterController == nil else { return }

        guard Bundle.main.bundleURL.pathExtension == "app" else {
            availability = .requiresAppBundle
            return
        }

        guard
            let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feedURLString)
        else {
            availability = .missingFeedURL
            self.feedURL = nil
            return
        }

        guard
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            availability = .missingPublicKey
            self.feedURL = feedURL
            return
        }

        self.feedURL = feedURL

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        availability = .ready
        bind(updater: updaterController.updater)
        refreshPublishedValues(from: updaterController.updater)
    }

    func checkForUpdates() {
        guard availability.isAvailable else { return }
        updaterController?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        refreshPublishedValues(from: updater)
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        refreshPublishedValues(from: updater)
    }

    private func bind(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
                // A finished check makes checking possible again; pick up its date.
                self?.lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyChecksForUpdates in
                self?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyDownloadsUpdates in
                self?.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            }
            .store(in: &cancellables)
    }

    func refreshLastUpdateCheckDate() {
        lastUpdateCheckDate = updaterController?.updater.lastUpdateCheckDate
    }

    private func refreshPublishedValues(from updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
}
