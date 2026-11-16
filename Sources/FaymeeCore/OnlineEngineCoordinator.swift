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

/// 连接 `OnlineModelSettings` 与两条管线，负责运行期无重启热切换、连接测试及过期测试取消
@MainActor @Observable
public final class OnlineEngineCoordinator {
    public typealias TranscriptionFactory = @MainActor (OnlineModelSettings, any HTTPTransport) -> (
        transcriber: any Transcriber, name: String, isReady: Bool
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
    @ObservationIgnored private let syncDebounce: Duration
    @ObservationIgnored private let dashScopeTestPollInterval: Duration

    @ObservationIgnored private weak var transcription: TranscriptionPipeline?
    @ObservationIgnored private weak var minutes: MinutesPipeline?

    @ObservationIgnored private var observedTranscription: ObservedSpec<OnlineTranscriptionProvider>
    @ObservationIgnored private var observedMinutes: ObservedSpec<OnlineMinutesProvider>
    @ObservationIgnored private var appliedTranscription: EffectiveSpec<OnlineTranscriptionProvider>
    @ObservationIgnored private var appliedMinutes: EffectiveSpec<OnlineMinutesProvider>

    @ObservationIgnored private var pendingSyncTask: Task<Void, Never>?
    @ObservationIgnored private let transcriptionTestRunner = ConnectionTestRunner()
    @ObservationIgnored private let minutesTestRunner = ConnectionTestRunner()

    public init(
        settings: OnlineModelSettings,
        transport: any HTTPTransport,
        makeTranscription: @escaping TranscriptionFactory,
        makeMinutes: @escaping MinutesFactory,
        syncDebounce: Duration = .zero,
        dashScopeTestPollInterval: Duration = .seconds(1)
    ) {
        self.settings = settings
        self.transport = transport
        self.makeTranscription = makeTranscription
        self.makeMinutes = makeMinutes
        self.syncDebounce = syncDebounce
        self.dashScopeTestPollInterval = dashScopeTestPollInterval
        self.observedTranscription = ObservedSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        self.observedMinutes = ObservedSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        self.appliedTranscription = EffectiveSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        self.appliedMinutes = EffectiveSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
    }

    /// 绑定管线并订阅配置变化；调用前管线应已按当前 `settings` 初始化，避免启动时重复创建引擎
    public func bind(transcription: TranscriptionPipeline, minutes: MinutesPipeline) {
        self.transcription = transcription
        self.minutes = minutes
        observedTranscription = ObservedSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        observedMinutes = ObservedSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        appliedTranscription = EffectiveSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        appliedMinutes = EffectiveSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        settings.onChange = { [weak self] in
            self?.handleSettingsChanged()
        }
    }

    /// 立即同步尚未落地的配置改动（取消输入防抖）
    public func flushSync() {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil

        let nextT = EffectiveSpec(
            mode: settings.transcriptionMode,
            provider: settings.transcriptionProvider,
            config: settings.activeTranscriptionConfig
        )
        if nextT != appliedTranscription {
            appliedTranscription = nextT
            let resolved = makeTranscription(settings, transport)
            transcription?.setEngine(transcriber: resolved.transcriber, engine: resolved.name, isReady: resolved.isReady)
        }

        let nextM = EffectiveSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        if nextM != appliedMinutes {
            appliedMinutes = nextM
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
        if nextT != observedTranscription {
            if nextT.mode != observedTranscription.mode || nextT.provider != observedTranscription.provider {
                discreteChange = true
            }
            observedTranscription = nextT
            transcriptionTestRunner.reset { transcriptionTestState = $0 }
        }

        let nextM = ObservedSpec(
            mode: settings.minutesMode,
            provider: settings.minutesProvider,
            config: settings.activeMinutesConfig
        )
        if nextM != observedMinutes {
            if nextM.mode != observedMinutes.mode || nextM.provider != observedMinutes.provider {
                discreteChange = true
            }
            observedMinutes = nextM
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

private struct ObservedSpec<Provider: Equatable>: Equatable {
    var mode: EngineMode
    var provider: Provider
    var config: OnlineEndpointConfig
}

private enum EffectiveSpec<Provider: Equatable>: Equatable {
    case local
    case online(provider: Provider, config: OnlineEndpointConfig)

    init(mode: EngineMode, provider: Provider, config: OnlineEndpointConfig) {
        switch mode {
        case .local: self = .local
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
