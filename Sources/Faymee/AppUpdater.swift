import AppKit
import Combine
import Observation
import Sparkle

/// 自动更新（Sparkle）。只有发布构建启用：build.sh release 才往 Info.plist 写 SUFeedURL，
/// 开发构建没有它，不建 updater，免得本机调试的版本被线上版本覆盖。
///
/// 会议中不打扰：定时检查发现新版本不弹窗，只在菜单栏面板里显示一行（gentle reminder），用户点了才弹
/// Sparkle 的窗口；录音或整理中点了“安装并重新启动”，推迟到录音整理完再重启，
/// 否则退出时的收尾会把正在录的会议截断
@MainActor @Observable
final class AppUpdater: NSObject {
    /// 发布构建才有 updater；为 false 时界面不显示更新相关的入口
    let isEnabled: Bool
    /// 定时检查发现、用户还没看过的新版本号，菜单栏面板据此显示“有新版本”
    private(set) var availableVersion: String?
    /// 用户已经同意安装、等录音整理完再重启
    private(set) var isInstallPostponed = false
    /// 正在检查或下载时为 false，“检查更新”按钮据此置灰
    private(set) var canCheckForUpdates = false
    /// “自动检查更新”开关，设置窗口里绑定它；值存在 Sparkle 自己的 UserDefaults 键里
    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    /// 正在录音或整理。AppModel 在会议状态变化时同步；变为空闲时执行推迟的安装
    var isBusy = false {
        didSet {
            guard !isBusy, let install = postponedInstall else { return }
            postponedInstall = nil
            isInstallPostponed = false
            install()
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var postponedInstall: (() -> Void)?
    @ObservationIgnored private var canCheckObservation: AnyCancellable?

    override init() {
        isEnabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        automaticallyChecks = false
        super.init()
        guard isEnabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                      userDriverDelegate: self)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    /// 菜单里的“检查更新…”和“有新版本”那一行都走这里：由 Sparkle 显示更新窗口。
    /// 菜单栏程序不在前台，先激活，否则窗口落在别的 App 后面
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension AppUpdater: @preconcurrency SPUUpdaterDelegate {
    /// 用户点了“安装并重新启动”：录音或整理中先不重启，等 isBusy 变回 false
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        postponedInstall = installHandler
        isInstallPostponed = true
        return true
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 定时检查发现的新版本一律不弹窗，改在菜单栏面板里提示（用户主动检查不经过这里）
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
