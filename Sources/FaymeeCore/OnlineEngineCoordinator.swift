import Foundation
import Observation

/// 设置页在线连接测试状态
public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case testing
    case succeeded
    case failed(String)

    public var isTesting: Bool {
        if case .testing = self { true } else { false }
    }
}

/// 连接 `OnlineModelSettings`、本机模型选择（`ModelSelections`）与两条管线，负责运行期无重启热切换、
/// 连接测试及过期测试取消。本机模式下所选模型变了也重建引擎；在线模式下改本机选择不动，回到本机时才用上。
/// 会后转写的本机模型下载完成或被删除时重新判断转写引擎就绪与否（只在本机模式下），排队的会议据此开始或继续等
@MainActor @Observable
public final class OnlineEngineCoordinator {
    /// `waitReason` 为 nil 表示就绪
    public typealias TranscriptionFactory = @MainActor (OnlineModelSettings, any HTTPTransport) -> (
        transcriber: any Transcriber, name: String, waitReason: TranscriptionWaitReason?
    )
    public typealias MinutesFactory = @MainActor (OnlineModelSettings, any HTTPTransport) -> (
        generator: any TextGenerator, name: String, requiresPower: Bool, isOnline: Bool
    )

    public private(set) var transcriptionTestState: ConnectionTestState = .idle
    public private(set) var minutesTestState: ConnectionTestState = .idle

    @ObservationIgnored private let settings: OnlineModelSettings
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let makeTranscription: TranscriptionFactory
    @ObservationIgnored private let makeMinutes: MinutesFactory
    @ObservationIgnored private let selections: ModelSelections?
    @ObservationIgnored private let downloads: ModelDownloads?
    @ObservationIgnored private let syncDebounce: Duration
    @ObservationIgnored private let dashScopeTestPollInterval: Duration

    @ObservationIgnored private weak var transcription: TranscriptionPipeline?
    @ObservationIgnored private weak var minutes: MinutesPipeline?

    @ObservationIgnored private var specs: SpecSnapshots

    @ObservationIgnored private var pendingSyncTask: Task<Void, Never>?
    @ObservationIgnored private let transcriptionTestRunner = ConnectionTestRunner()
    @ObservationIgnored private let minutesTestRunner = ConnectionTestRunner()

    public init(
        settings: OnlineModelSettings,
        transport: any HTTPTransport,
        makeTranscription: @escaping TranscriptionFactory,
        makeMinutes: @escaping MinutesFactory,
        selections: ModelSelections? = nil,
        downloads: ModelDownloads? = nil,
        syncDebounce: Duration = .zero,
        dashScopeTestPollInterval: Duration = .seconds(1)
    ) {
        self.settings = settings
        self.transport = transport
        self.makeTranscription = makeTranscription
        self.makeMinutes = makeMinutes
        self.selections = selections
        self.downloads = downloads
        self.syncDebounce = syncDebounce
        self.dashScopeTestPollInterval = dashScopeTestPollInterval
        self.specs = SpecSnapshots(settings: settings, transcriptionModel: selections?.selectedID(for: .transcription),
                                   minutesModel: selections?.selectedID(for: .minutes))
    }

    /// 绑定管线并订阅配置变化；调用前管线应已按当前 `settings` 初始化，避免启动时重复创建引擎。
    /// 订阅会后转写模型（含还隐藏的目录项）下载器的可用性变化
    public func bind(transcription: TranscriptionPipeline, minutes: MinutesPipeline) {
        self.transcription = transcription
        self.minutes = minutes
        syncObservedAndAppliedSpecs()
        settings.onChange = { [weak self] in
            self?.handleSettingsChanged()
        }
        // 本机模型选择是离散的改动，立即同步
        selections?.observe { [weak self] role in
            if role == .transcription || role == .minutes { self?.flushSync() }
        }
        if let downloads {
            for model in downloads.catalog.models where model.roles.contains(.transcription) {
                downloads.downloader(for: model)?.observeAvailability { [weak self] in
                    self?.transcriptionModelAvailabilityChanged()
                }
            }
        }
    }

    /// 会后转写的本机模型下载完成或被删除：本机模式下按现在的选择重建引擎，就绪与否（等下载）随之更新，
    /// 就绪后排队的会议自动开始。在线模式下不动，免得盖掉在线引擎的就绪状态
    public func transcriptionModelAvailabilityChanged() {
        guard case .local = specs.appliedTranscription else { return }
        let resolved = makeTranscription(settings, transport)
        applyTranscription(resolved)
    }

    private func applyTranscription(
        _ resolved: (transcriber: any Transcriber, name: String, waitReason: TranscriptionWaitReason?)
    ) {
        transcription?.setEngine(transcriber: resolved.transcriber, engine: resolved.name,
                                 isReady: resolved.waitReason == nil,
                                 waitReason: resolved.waitReason ?? .onlineConfig)
    }

    private func syncObservedAndAppliedSpecs() {
        specs = SpecSnapshots(settings: settings, transcriptionModel: selections?.selectedID(for: .transcription),
                              minutesModel: selections?.selectedID(for: .minutes))
    }

    /// 立即同步尚未落地的配置改动（取消输入防抖）
    public func flushSync() {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil

        let nextT = EffectiveSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig,
            localModel: selections?.selectedID(for: .transcription)
        )
        if nextT != specs.appliedTranscription {
            specs.appliedTranscription = nextT
            applyTranscription(makeTranscription(settings, transport))
        }

        let nextM = EffectiveSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig,
            localModel: selections?.selectedID(for: .minutes)
        )
        if nextM != specs.appliedMinutes {
            specs.appliedMinutes = nextM
            let resolved = makeMinutes(settings, transport)
            minutes?.setEngine(
                generator: resolved.generator,
                model: resolved.name,
                requiresPower: resolved.requiresPower,
                isOnlineEngine: resolved.isOnline
            )
        }
    }

    @discardableResult
    public func testTranscriptionConnection() -> Task<Void, Never> {
        let provider = settings.transcriptionProvider
        let config = settings.activeTranscriptionConfig
        let transport = self.transport
        let pollInterval = self.dashScopeTestPollInterval
        return transcriptionTestRunner.start(
            onState: { [weak self] state in
                self?.transcriptionTestState = state
                if state == .succeeded { self?.flushSync() }
            },
            operation: {
                try await OnlineTranscriptionEngine.testConnection(
                    provider: provider,
                    config: config,
                    transport: transport,
                    dashScopePollInterval: pollInterval
                )
            }
        )
    }

    @discardableResult
    public func testMinutesConnection() -> Task<Void, Never> {
        let provider = settings.minutesProvider
        let config = settings.activeMinutesConfig
        let transport = self.transport
        return minutesTestRunner.start(
            onState: { [weak self] state in
                self?.minutesTestState = state
                if state == .succeeded { self?.flushSync() }
            },
            operation: {
                try await OnlineMinutesEngine.testConnection(
                    provider: provider,
                    config: config,
                    transport: transport
                )
            }
        )
    }

    /// 关闭设置窗口等场景下取消尚未完成的连接测试，避免后台遗留无主请求
    public func cancelInFlightConnectionTests() {
        transcriptionTestRunner.cancelIfTesting(
            onState: { transcriptionTestState = $0 },
            current: transcriptionTestState
        )
        minutesTestRunner.cancelIfTesting(
            onState: { minutesTestState = $0 },
            current: minutesTestState
        )
    }

    private func handleSettingsChanged() {
        var discreteChange = false

        let nextT = ObservedSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        if nextT != specs.observedTranscription {
            if nextT.mode != specs.observedTranscription.mode || nextT.provider != specs.observedTranscription.provider {
                discreteChange = true
            }
            specs.observedTranscription = nextT
            transcriptionTestRunner.reset { transcriptionTestState = $0 }
        }

        let nextM = ObservedSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        if nextM != specs.observedMinutes {
            if nextM.mode != specs.observedMinutes.mode || nextM.provider != specs.observedMinutes.provider {
                discreteChange = true
            }
            specs.observedMinutes = nextM
            minutesTestRunner.reset { minutesTestState = $0 }
        }

        if syncDebounce <= .zero || discreteChange {
            flushSync()
        } else {
            scheduleDebouncedSync()
        }
    }

    private func scheduleDebouncedSync() {
        pendingSyncTask?.cancel()
        let delay = syncDebounce
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushSync()
        }
    }
}

private struct SpecSnapshots {
    var observedTranscription: ObservedSpec<OnlineTranscriptionProvider>
    var observedMinutes: ObservedSpec<OnlineMinutesProvider>
    var appliedTranscription: EffectiveSpec<OnlineTranscriptionProvider>
    var appliedMinutes: EffectiveSpec<OnlineMinutesProvider>

    @MainActor
    init(settings: OnlineModelSettings, transcriptionModel: String?, minutesModel: String?) {
        let transcription = ObservedSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        let minutes = ObservedSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        observedTranscription = transcription
        observedMinutes = minutes
        appliedTranscription = EffectiveSpec(transcription, localModel: transcriptionModel)
        appliedMinutes = EffectiveSpec(minutes, localModel: minutesModel)
    }
}

private struct ObservedSpec<Provider: Equatable>: Equatable {
    var mode: EngineMode
    var provider: Provider
    var config: OnlineEndpointConfig
}

/// 实际生效的引擎。本机时带上所选的目录项 id（还没接目录的用途为 nil），换了模型也算变化
private enum EffectiveSpec<Provider: Equatable>: Equatable {
    case local(model: String?)
    case online(provider: Provider, config: OnlineEndpointConfig)

    init(_ observed: ObservedSpec<Provider>, localModel: String? = nil) {
        self.init(mode: observed.mode, provider: observed.provider, config: observed.config, localModel: localModel)
    }

    init(mode: EngineMode, provider: Provider, config: OnlineEndpointConfig, localModel: String? = nil) {
        switch mode {
        case .local: self = .local(model: localModel)
        case .online: self = .online(provider: provider, config: config)
        }
    }
}

@MainActor
private final class ConnectionTestRunner {
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(
        onState: @escaping @MainActor (ConnectionTestState) -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> {
        task?.cancel()
        generation += 1
        let token = generation
        onState(.testing)

        let launched = Task { @MainActor [weak self] in
            do {
                try await operation()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                onState(.succeeded)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                onState(.failed(error.localizedDescription))
            }
        }
        task = launched
        return launched
    }

    func reset(onState: @MainActor (ConnectionTestState) -> Void) {
        task?.cancel()
        task = nil
        generation += 1
        onState(.idle)
    }

    func cancelIfTesting(onState: @MainActor (ConnectionTestState) -> Void, current: ConnectionTestState) {
        guard current.isTesting else { return }
        reset(onState: onState)
    }
}
