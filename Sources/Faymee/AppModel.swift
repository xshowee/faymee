import AppKit
import AVFoundation
import FaymeeCore
import Foundation
import Observation
import os

private let systemSoundLog = Logger(subsystem: "com.faymee.app", category: "system-sound")

@MainActor @Observable
final class AppModel {
    /// 多久没收到音频数据视为采集停滞，重建引擎
    static let stallAfter: TimeInterval = 5

    // 转写是否暂停由这几项决定，变化时统一重新计算，不靠各处手动同步
    private(set) var meetings: [Meeting] = [] {
        didSet { syncTranscriptionSuspension() }
    }
    private(set) var current: Meeting? {
        didSet {
            syncTranscriptionSuspension()
            syncHotkeys()
        }
    }
    private(set) var elapsed: TimeInterval = 0
    private(set) var levelDB: Float = -160
    private(set) var isSilent = false
    /// 正在录音的麦克风，每开一个新分片更新一次
    private(set) var recordingDevice: AudioInputDevice?
    /// 录音过程中出错（写盘失败、麦克风不可用、采集停滞），直到成功开出新分片才清除
    private(set) var hasRecordingError = false
    var lastError: String?
    /// 系统级休眠是否已关闭（Caffy 开启）。熄屏录音依赖它，否则系统无操作一段时间后会休眠
    private(set) var sleepDisabled = true

    /// 热词表原文，编辑框直接绑定。整理后立即交给转写管线，停止输入片刻后写盘；
    /// 只影响之后开始的转写，已有会议不会自动重转
    var hotwordsText = "" {
        didSet {
            guard hotwordsText != oldValue else { return }
            hotwords = Hotwords.parse(hotwordsText)
            if hotwordsText != savedHotwords { scheduleHotwordsSave() }
        }
    }
    /// 整理后的热词，每次编辑只算一次
    private(set) var hotwords: [String] = [] {
        didSet { transcription.hotwords = hotwords }
    }
    /// 热词表读不出来或没能保存，显示在热词表窗口里
    private(set) var hotwordsError: String?

    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var defaultInputUID: String?
    /// 用户选择的麦克风，记在 UserDefaults。录音中修改会立即切换（从新分片开始）
    var inputSelection: InputSelection {
        didSet {
            guard inputSelection != oldValue else { return }
            UserDefaults.standard.set(inputSelection.storage, forKey: "inputSelection")
            if case let .device(uid) = inputSelection, let d = inputDevices.first(where: { $0.uid == uid }) {
                selectedDeviceName = d.name
                UserDefaults.standard.set(d.name, forKey: "inputDeviceName")
            }
            reconcileDevice()
        }
    }
    /// 指定设备的名字，设备拔掉后仍能在界面上显示“XX（未连接）”
    private(set) var selectedDeviceName: String?

    /// “系统声音”开关，记在 UserDefaults，默认关闭。录音前、录音中都能切换：
    /// 录音中切换时立即开始或停止采集，并在会议的系统声音时段里开一段或结束一段
    var systemSoundEnabled: Bool {
        didSet {
            guard systemSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(systemSoundEnabled, forKey: "systemSound")
            syncSystemSound()
        }
    }
    /// 系统声音采集此刻真的在跑（开关打开但建不起来时为 false），菜单栏图标据此区别显示
    private(set) var isCapturingSystemSound = false
    /// 录音中系统声音那一路是否可用、要不要重试。打开开关（或开着开关开始录音）时换一个新的，停止录音、
    /// 关掉开关时复位
    private(set) var systemSoundAvailability = SystemSoundAvailability()
    /// 录音中系统声音不可用的原因，菜单栏面板据此显示“系统声音不可用”
    var systemSoundUnavailableReason: SystemSoundUnavailableReason? { systemSoundAvailability.unavailableReason }
    /// 不在录音时打开开关就查到的不可用原因（没有授权），菜单栏面板录音前就提示。关掉开关、开始录音时清掉
    private(set) var systemSoundIdleUnavailableReason: SystemSoundUnavailableReason?

    /// 按当前选择和设备状态，开始录音时会用哪个麦克风
    var plannedDevice: AudioInputDevice? {
        inputSelection.resolve(in: inputDevices, lidClosed: SystemState.isLidClosed == true)
            ?? inputDevices.first { $0.uid == defaultInputUID }
    }

    var isRecording: Bool { current != nil }
    /// 正在合盖、用的又是内置麦克风：此刻没有在录到声音
    var isLidGapOpen: Bool { current?.openGap != nil }

    @ObservationIgnored let store: MeetingStore
    /// 自动更新。录音、整理期间推迟重启，由 syncTranscriptionSuspension 同步忙闲
    @ObservationIgnored let updater = AppUpdater()
    /// 声纹库。界面（说话人菜单、声纹管理窗口）经它读写；转写管线识别时自己读盘
    @ObservationIgnored let voiceprints = VoiceprintLibraryModel()
    @ObservationIgnored private let hotwordStore = HotwordStore()
    /// 热词表文件里现在的内容（上次读到或存下的），保存前用它核对文件没被别处改过
    @ObservationIgnored private var savedHotwords = ""
    @ObservationIgnored private var pendingHotwordsSave: Task<Void, Never>?
    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private let systemSound = SystemSoundCapture()
    /// 每开始一次系统声音采集的尝试、每停一次采集加一：尝试中途 await 回来时据此判断这次还算不算数
    @ObservationIgnored private var systemSoundAttempt = 0
    /// 每次录音前查授权加一，同上
    @ObservationIgnored private var systemSoundIdleCheck = 0
    /// 录音前打开开关时为弹出授权框保留的采集还在不在等（ticket 15）
    @ObservationIgnored private var systemSoundPrompt = SystemSoundAuthorizationPrompt()
    /// 在等授权框的那个任务，结果是最后查到的授权。录音中的采集尝试等它，不另建
    @ObservationIgnored private var systemSoundPromptTask: Task<SystemSoundAuthorization, Never>?
    /// 每开始、结束一次等授权框加一：任务中途 await 回来时据此判断还算不算数。开始、停止录音不影响它
    @ObservationIgnored private var systemSoundPromptToken = 0
    @ObservationIgnored private var timer: Timer?
    /// “没有声音”的判断：麦克风电平随到随喂，系统声音电平每秒从采集取一次
    @ObservationIgnored private var silence = SilenceWatch()
    @ObservationIgnored private var lastStallRestart = Date.distantPast
    /// 启动时的中断恢复和转写、纪要恢复是否已完成，之前不开始转写和纪要
    @ObservationIgnored private var launchRecovered = false {
        didSet { syncTranscriptionSuspension() }
    }

    /// 本机模型目录里需要下载的模型的下载器，每个模型一个（`ModelPicker` 和各管线共用）
    @ObservationIgnored let modelDownloads = ModelDownloads(directory: LocalModel.defaultDirectory,
                                                            transport: URLSessionModelTransport())
    /// 每个用途选中的本机模型（设置里的选择框）。会后转写的默认值看是否已有会议，在 init 里一次决定。
    /// 转写、纪要管线和声纹模型（lazy）都读它，而 meetings 的 didSet 在 init 里就会建出这些管线：
    /// 必须是没有默认值的 let，编译器才保证它在 self 能被用到（任何 didSet、lazy 跑起来）之前已经赋值
    @ObservationIgnored let modelSelections: ModelSelections

    /// 设置里「声纹」选中的模型 → 转写管线的区分引擎和匹配阈值。打进 App 的模型由 build.sh 拷进
    /// Contents/Resources；直接 swift run（没打包）时没有，不区分说话人
    @ObservationIgnored private(set) lazy var voiceprintModel = VoiceprintModelBinding(
        selections: modelSelections, downloads: modelDownloads, bundleResources: Bundle.main.resourceURL)

    /// 设置里的「重算声纹库」：换声纹模型后用新模型从原会议录音重算。每写回一个人，声纹库界面跟着重读
    @ObservationIgnored private(set) lazy var voiceprintRecomputation: VoiceprintRecomputation = {
        let r = VoiceprintRecomputation(voiceprints: voiceprints.store, meetings: store)
        r.onLibraryChange = { [weak self] in self?.voiceprints.reload() }
        return r
    }()

    /// 设置里选中的声纹模型 id。声纹库里模型与它不同的人不参与识别、需要重算或重新登记
    var selectedVoiceprintModel: String? { modelSelections.selectedID(for: .voiceprint) }

    /// 所选声纹模型能不能用（打进 App 的总能用，需要下载的看是否下好）
    var selectedVoiceprintModelIsReady: Bool {
        guard let selected = modelSelections.selected(for: .voiceprint) else { return false }
        // 读下载器的状态（可观察），下载完成时界面跟着变
        return modelDownloads.downloader(for: selected)?.isReady ?? modelDownloads.isReady(selected)
    }

    /// 声纹模型现在不能删的原因：正在转写（可能接着区分说话人）或重算声纹库时，引擎还要读模型文件
    var voiceprintModelDeleteBlockedReason: String? {
        if voiceprintRecomputation.isRunning { return "正在重算声纹库，结束后才能删除模型" }
        return transcriptionModelDeleteBlockedReason
    }

    /// 会后转写模型现在不能删的原因：正在转写（可能接着区分说话人）时引擎还要读模型文件
    /// （读到一半的模型会让 sherpa-onnx 直接退出进程）
    var transcriptionModelDeleteBlockedReason: String? {
        transcription.activeID != nil ? "正在转写或区分说话人，结束后才能删除模型" : nil
    }

    /// 会后转写、实时字幕定稿选择框里的模型现在不能删的原因。Paraformer、Fun-ASR-Nano 两个用途共用同一份模型文件，
    /// 哪边在用都不能删：正在转写（同上），或本场录音的实时字幕定稿正拿着它（删到一半同样会让 sherpa-onnx 退出进程）
    func asrModelDeleteBlockedReason(_ m: CatalogModel) -> String? {
        if liveFinalizeModelID == m.id { return "本场录音的实时字幕定稿正在用它，录音结束后才能删除" }
        return m.roles.contains(.transcription) ? transcriptionModelDeleteBlockedReason : nil
    }

    /// App 退出前：取消在后台用 onnxruntime 的会后任务（会后转写、区分说话人、重算声纹库），
    /// 之后由调用方等它们放掉模型（`SherpaBackgroundWork.waitUntilReleased`）。
    /// 转写管线暂停即取消正在进行的那场并放回队首、状态记为排队，下次启动照常恢复；重算声纹库已写回的人保留
    func cancelBackgroundWorkForQuit() {
        transcription.isSuspended = true
        voiceprintRecomputation.cancel()
    }

    /// 用所选声纹模型重算声纹库；所选模型还不能用（没下载）时什么都不做
    func recomputeVoiceprints() {
        guard let extractor = voiceprintModel.makeExtractor() else { return }
        voiceprintRecomputation.start(with: extractor)
    }

    /// 选中的纪要模型的下载器（详情页纪要等模型时显示它）。只在用户点“下载”时开始；
    /// 下载完成或删除模型时通知纪要管线（见 init）
    var modelDownloader: ModelDownloader {
        modelDownloads.downloader(for: MinutesEngine.selectedModel(modelSelections))!
    }

    /// 在线转写与在线纪要设置，API Key 存于系统钥匙串；默认保持纯本机模式
    @ObservationIgnored let onlineSettings = OnlineModelSettings(
        defaults: .standard,
        credentials: KeychainCredentialStore()
    )
    @ObservationIgnored private let httpTransport = URLSessionHTTPTransport()
    @ObservationIgnored private lazy var onlineCoordinator = OnlineEngineCoordinator(
        settings: onlineSettings,
        transport: httpTransport,
        makeTranscription: { [unowned self] in
            TranscriptionEngine.make(settings: $0, transport: $1, selections: modelSelections,
                                     downloads: modelDownloads)
        },
        makeMinutes: { [unowned self] in
            MinutesEngine.make(settings: $0, transport: $1, selections: modelSelections)
        },
        selections: modelSelections,
        downloads: modelDownloads,
        syncDebounce: .milliseconds(500)
    )

    var transcriptionTestState: ConnectionTestState { onlineCoordinator.transcriptionTestState }
    var minutesTestState: ConnectionTestState { onlineCoordinator.minutesTestState }

    /// “转写完成后自动生成纪要”，记在 UserDefaults，默认打开，设置窗口里可以改
    var autoGenerateMinutes: Bool {
        didSet {
            UserDefaults.standard.set(autoGenerateMinutes, forKey: "autoGenerateMinutes")
            minutes.autoGenerate = autoGenerateMinutes
        }
    }

    /// “全局快捷键”开关，记在 UserDefaults，默认打开。录音中修改立即注册或注销。设置窗口里绑定它
    var globalShortcutsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(globalShortcutsEnabled, forKey: "globalShortcuts")
            syncHotkeys()
        }
    }
    /// 本次录音没注册上的全局快捷键（被其他 App 占用），菜单栏面板里说明。没在注册时为空
    private(set) var shortcutConflicts: [LiveShortcut] = []
    /// 刚标记了重点：菜单栏图标换成旗子约 2 秒（见 `MenuBarIndicator`）
    private(set) var showsMarkFlag = false
    @ObservationIgnored private let hotkeys = GlobalHotkeys()
    @ObservationIgnored private var markFlagReset: Task<Void, Never>?
    /// 启动就建好：它要一直记着最近在前台的别的 App，记完一笔把焦点还回去
    @ObservationIgnored private let noteInput = NoteInputController()

    /// “实时字幕”开关，记在 UserDefaults，默认打开。关闭时会中面板只显示标注和输入框，不跑引擎；
    /// 录音中修改立即生效。设置窗口里绑定它
    var liveCaptionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveCaptionsEnabled, forKey: "liveCaptions")
            livePanel.captionsEnabled = liveCaptionsEnabled
        }
    }
    /// 本场录音的实时字幕在用的模型 id（所选模型没下载完时是 SpeechAnalyzer）；不在录音时为 nil。
    /// 设置里据此不让删正在用的模型
    private(set) var liveCaptionModelID: String?
    /// 本场录音的实时字幕定稿在用的模型 id；不用（选了“不用”或所选模型没下载完）或不在录音时为 nil。
    /// 设置里据此不让删正在用的模型
    private(set) var liveFinalizeModelID: String?
    /// 本场录音的实时字幕，录音开始时建、停止时丢弃（字幕不存盘）。会中面板观察它
    private(set) var liveCaptions: LiveCaptions? {
        didSet {
            recorder.liveTap = liveCaptions?.tap
            systemSound.liveTap = liveCaptions?.systemSoundTap
            livePanel.captions = liveCaptions
        }
    }
    @ObservationIgnored private lazy var livePanel: LivePanelController = {
        let panel = LivePanelController(model: self)
        panel.captionsEnabled = liveCaptionsEnabled
        return panel
    }()
    /// 录音开始时是否自动打开会中面板：记住上次录音结束时面板开没开，默认不开（投屏时不突然出现）
    private var opensLivePanelOnStart: Bool {
        get { UserDefaults.standard.bool(forKey: "livePanelOpensOnStart") }
        set { UserDefaults.standard.set(newValue, forKey: "livePanelOpensOnStart") }
    }

    /// “区分说话人”开关，记在 UserDefaults，默认打开。关闭时完整转写跳过区分说话人；
    /// 只影响之后开始的转写。设置窗口里绑定它
    var diarizeSpeakers: Bool {
        didSet {
            UserDefaults.standard.set(diarizeSpeakers, forKey: "diarizeSpeakers")
            transcription.diarizes = diarizeSpeakers
        }
    }

    /// 会后转写队列。界面直接观察它的 queue / activeID / activity，手动转写调 enqueue；
    /// 会议的转写状态在 meeting.transcription 里，由本类作为 TranscriptionHost 写入
    @ObservationIgnored private(set) lazy var transcription: TranscriptionPipeline = {
        let engine = TranscriptionEngine.make(settings: onlineSettings, transport: httpTransport,
                                              selections: modelSelections, downloads: modelDownloads)
        let diarization = voiceprintModel.makeEngine()
        let pipeline = TranscriptionPipeline(store: store, transcriber: engine.transcriber,
                                             engine: engine.name, isEngineReady: engine.waitReason == nil,
                                             engineWaitReason: engine.waitReason ?? .onlineConfig,
                                             diarizer: diarization.diarizer,
                                             diarizerWaitReason: diarization.waitReason,
                                             voiceprints: VoiceprintStore(), host: self)
        pipeline.voiceprintThreshold = diarization.voiceprintThreshold
        pipeline.isSuspended = true
        pipeline.hotwords = hotwords
        pipeline.diarizes = diarizeSpeakers
        pipeline.onFinish = { [weak self] in self?.transcriptionFinished($0, $1) }
        voiceprintModel.bind(pipeline)
        return pipeline
    }()

    /// 纪要队列。界面观察它的 queue / activeID / activity，用 waitReason(for:) 取排队说明，
    /// 手动生成调 enqueue；会议的纪要状态在 meeting.minutes 里，由本类作为 MinutesHost 写入。
    /// 和转写管线互相让行（coordinate），录音、整理、启动恢复期间和转写一起暂停
    @ObservationIgnored private(set) lazy var minutes: MinutesPipeline = {
        let engine = MinutesEngine.make(settings: onlineSettings, transport: httpTransport,
                                        selections: modelSelections)
        let pipeline = MinutesPipeline(store: store, generator: engine.generator, model: engine.name,
                                       requiresPower: engine.requiresPower, isOnlineEngine: engine.isOnline,
                                       host: self)
        pipeline.isSuspended = true
        pipeline.isOnPower = SystemState.isOnPower
        pipeline.autoGenerate = autoGenerateMinutes
        pipeline.onFinish = { [weak self] in self?.minutesFinished($0, $1) }
        pipeline.coordinate(with: transcription)
        return pipeline
    }()

    init() {
        // 先读会议目录、定好各用途的模型，再做别的：已有安装的判断要看会议，而 meetings 一赋值就会建管线
        let store = MeetingStore()
        let loadedMeetings = store.loadAll()
        self.store = store
        modelSelections = .atLaunch(meetings: loadedMeetings)
        inputSelection = InputSelection(storage: UserDefaults.standard.string(forKey: "inputSelection"))
        selectedDeviceName = UserDefaults.standard.string(forKey: "inputDeviceName")
        autoGenerateMinutes = UserDefaults.standard.object(forKey: "autoGenerateMinutes") as? Bool ?? true
        diarizeSpeakers = UserDefaults.standard.object(forKey: "diarizeSpeakers") as? Bool ?? true
        globalShortcutsEnabled = UserDefaults.standard.object(forKey: "globalShortcuts") as? Bool ?? true
        liveCaptionsEnabled = UserDefaults.standard.object(forKey: "liveCaptions") as? Bool ?? true
        systemSoundEnabled = UserDefaults.standard.bool(forKey: "systemSound")
        hotkeys.onPress = { [weak self] in self?.shortcutPressed($0) }
        noteInput.onSave = { [weak self] text, time in self?.addNote(text, at: time) }
        meetings = loadedMeetings
        reloadHotwords()
        if let hotwordsError { lastError = hotwordsError }
        // 不依赖 init 里的赋值是否触发 hotwordsText 的 didSet，直接算一次
        hotwords = Hotwords.parse(hotwordsText)
        refreshDevices()
        AudioDevices.observeChanges { [weak self] in self?.refreshDevices() }
        // startEngine 总在主线程调用（开始录音、设备变化通知、定时器）
        recorder.deviceResolver = { [weak self] in
            MainActor.assumeIsolated {
                self?.inputSelection.resolve(in: AudioDevices.inputs(), lidClosed: SystemState.isLidClosed == true)
            }
        }
        recorder.onSegment = { [weak self] in self?.segmentOpened($0) }
        recorder.onLevel = { [weak self] in self?.levelChanged($0) }
        recorder.onError = { [weak self] in self?.recordingFailed($0) }
        systemSound.onDeviceLost = { [weak self] in self?.systemSoundDeviceLost() }
        systemSound.onFormatChanged = { [weak self] in self?.systemSoundFormatChanged() }
        // 睡眠期间 host time 不走而墙钟在走，唤醒后接着用原来的换算会把系统声音摆早：重建采集和时钟换算
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartSystemSoundCapture() }
        }
        SystemState.observePowerChanges { [weak self] in
            // 电量变化也会通知，只在接电状态变了时更新
            let onPower = SystemState.isOnPower
            guard let self, self.minutes.isOnPower != onPower else { return }
            self.minutes.isOnPower = onPower
        }
        // 下载完成：排队的纪要接着开始；删除模型：排队的纪要回到“等待下载模型”。
        // 每个纪要模型的下载器都接上：管线只看当前引擎的模型在不在
        for entry in modelSelections.catalog.models(for: .minutes) {
            modelDownloads.downloader(for: entry)?.observeAvailability { [weak self] in
                self?.minutes.modelAvailabilityChanged()
            }
        }
        Notifier.onAction = { [weak self] in self?.handleNoticeAction($0) }
        Notifier.setUp()
        onlineCoordinator.bind(transcription: transcription, minutes: minutes)
        Task {
            await recoverInterrupted()
            transcription.restore(meetings)
            minutes.restore(meetings)
            launchRecovered = true
        }
    }

    // MARK: - 录音

    func start() async {
        guard !isRecording else { return }
        lastError = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            lastError = "没有麦克风权限。请在“系统设置 › 隐私与安全性 › 麦克风”中允许 Faymee。"
            return
        }
        guard !isRecording else { return }
        do {
            let m = try store.create(startedAt: Date())
            meetings.insert(m, at: 0)
            // 录音可靠性优先：正在进行的转写立即取消（见 syncTranscriptionSuspension）
            current = m
            do {
                try recorder.start(directory: store.segmentsDirectory(m.id))
            } catch {
                current = nil
                var failed = m
                failed.status = .failed
                failed.error = error.localizedDescription
                update(failed)
                throw error
            }
        } catch {
            lastError = "无法开始录音：\(error.localizedDescription)"
            return
        }
        elapsed = 0
        isSilent = false
        hasRecordingError = false
        // 录音中的提示由 systemSoundAvailability 接手，还没回来的录音前查询作废
        systemSoundIdleCheck += 1
        systemSoundIdleUnavailableReason = nil
        silence = SilenceWatch()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 开着开关开始录音：系统声音时段从录音开始算起
        syncSystemSound(at: current?.startedAt ?? Date())
        startLiveCaptions()
    }

    func stop() {
        guard current != nil else { return }
        // 先收下正在输入的笔记：下面停止录音会用此刻的会议覆盖写盘
        noteInput.saveIfOpen()
        livePanel.saveDraft()
        guard var m = current else { return }
        // 结束时间在拆采集之前取：系统声音时段和录音同时结束（会议详情的音源标记按两者起止比较）
        let endedAt = Date()
        stopLiveCaptions()
        recorder.stop()
        // 打开时的回调可能还没切回主线程：停下后把报过的分片补记进这份会议，整理才不会丢掉它们
        stopSystemSoundCapture(into: &m)
        timer?.invalidate()
        timer = nil
        m.endedAt = endedAt
        m.endOpenPeriods(at: endedAt)
        systemSoundAvailability = SystemSoundAvailability()
        current = nil
        isSilent = false
        hasRecordingError = false
        levelDB = -160
        recordingDevice = nil
        update(m)
        Task { await finalize(m.id) }
    }

    private func segmentOpened(_ segment: Segment) {
        guard var m = current else { return }
        // 重建采集时空分片被删掉、编号复用，同名的那条换成新的，不重复记
        if let i = m.segments.firstIndex(where: { $0.file == segment.file }) {
            m.segments[i] = segment
        } else {
            m.segments.append(segment)
        }
        recordingDevice = recorder.currentDevice
        if hasRecordingError {
            hasRecordingError = false
            lastError = nil
        }
        update(m)
    }

    // MARK: - 系统声音
    //
    // 线程：这里的状态（开关、可用性、会议）都只在主线程读写。查授权要起子进程，在后台线程等它退出；
    // 建 IOProc 可能卡在授权框上，由 SystemSoundCapture 连同 tap、聚合设备放到它自己的后台队列。两者都用 await 等，
    // 结果回到主线程后先核对这次尝试还算不算数（systemSoundAttempt），再改状态

    /// 让录音中的系统声音跟上开关：打开时开一段时段、开始采集，关闭时停止采集、结束这段。
    /// 不在录音时只查授权（开始录音时再调一次）。采集不可用时麦克风照常录，时段照样记（它记的是开关）
    private func syncSystemSound(at date: Date = Date()) {
        // 关掉开关：为授权框保留的采集拆掉，录音中在等它的采集尝试下面一起作废
        if !systemSoundEnabled { cancelSystemSoundPrompt() }
        guard var m = current else {
            checkSystemSoundBeforeRecording()
            return
        }
        if systemSoundEnabled, !m.isSystemSoundPeriodOpen {
            // 时段先记下、写盘，再建采集：时段记的是开关，不等 tap 建好（建的时候可能在等授权）。
            // 一开始就不可用时，不可用时段和开关时段起点相同
            m.beginSystemSoundPeriod(at: date)
            update(m)
            systemSoundAvailability = SystemSoundAvailability()
            startSystemSoundCapture(for: m.id, at: date)
        } else if !systemSoundEnabled, m.isSystemSoundPeriodOpen {
            stopSystemSoundCapture(into: &m)
            // 仍在进行的不可用时段一起结束
            m.endSystemSoundPeriod(at: date)
            update(m)
            systemSoundAvailability = SystemSoundAvailability()
        }
    }

    /// 菜单栏面板打开时：录音前提示过没有授权的再查一次，用户可能已经在系统设置里打开了
    func recheckSystemSoundBeforeRecording() {
        guard current == nil, systemSoundIdleUnavailableReason != nil else { return }
        checkSystemSoundBeforeRecording()
    }

    /// 不在录音时打开开关：未决定就让系统弹出授权框（见 `promptSystemSoundAuthorization`），拒绝就在面板里提示
    /// 没有授权（spec 用户故事 6、7）。关掉开关时清掉提示。不录、不写盘，也不开不可用时段（还没有会议）。
    /// 查询结果回来时已经开始录音、关了开关或又查了一次，这次就作废
    private func checkSystemSoundBeforeRecording() {
        systemSoundIdleCheck += 1
        let check = systemSoundIdleCheck
        guard systemSoundEnabled else {
            systemSoundIdleUnavailableReason = nil
            return
        }
        Task {
            let action = SystemSoundSwitchOn(authorization: await SystemSoundAuthorizationQuery.current())
            guard isCurrentIdleCheck(check) else { return }
            systemSoundIdleUnavailableReason = action.unavailableReason
            guard action == .requestAuthorization else { return }
            promptSystemSoundAuthorization()
        }
    }

    /// 让系统弹出授权框，并等用户回答：建一次采集保留着，每秒在子进程里查授权，查到回答或建好后满 2 分钟才拆掉
    /// （`SystemSoundAuthorizationPrompt`）。等的期间开始录音不影响它，录音中的采集尝试等它的结果。
    /// 有结果时不在录音、开关还开着，就按结果更新录音前的提示。已经在等时什么也不做
    private func promptSystemSoundAuthorization() {
        guard !systemSoundPrompt.isPending else { return }
        systemSoundPromptToken += 1
        let token = systemSoundPromptToken
        systemSoundPrompt.begin()
        systemSoundPromptTask = Task { await awaitSystemSoundPrompt(token) }
    }

    /// 等授权框的过程，返回最后查到的授权。中途被关掉开关作废时返回未决定（这时没有人用这个结果）
    private func awaitSystemSoundPrompt(_ token: Int) async -> SystemSoundAuthorization {
        let held = await systemSound.holdForAuthorizationPrompt()
        guard token == systemSoundPromptToken else { return .undetermined }
        guard held else {
            // 建不起来：没有在等的授权框，查一次就结束（开始录音时照常按建立失败处理）
            systemSoundPrompt.holdFailed()
            let authorization = await SystemSoundAuthorizationQuery.current()
            guard token == systemSoundPromptToken else { return .undetermined }
            finishSystemSoundPrompt(authorization)
            return authorization
        }
        systemSoundPrompt.held(at: Date())
        while true {
            let authorization = await SystemSoundAuthorizationQuery.current()
            guard token == systemSoundPromptToken else { return .undetermined }
            switch systemSoundPrompt.checked(authorization, at: Date()) {
            case let .recheck(after: interval):
                try? await Task.sleep(for: .seconds(interval))
                guard token == systemSoundPromptToken else { return .undetermined }
            case let .release(result):
                systemSoundLog.info("授权框有结果（\(result.childOutput, privacy: .public)），拆掉为它保留的采集")
                systemSound.releaseAuthorizationPromptHold()
                finishSystemSoundPrompt(result)
                return result
            }
        }
    }

    /// 等授权框结束（拆掉保留的采集之后）。不在录音、开关还开着时按结果更新录音前的提示：
    /// 录音中的提示由 systemSoundAvailability 管
    private func finishSystemSoundPrompt(_ authorization: SystemSoundAuthorization) {
        systemSoundPromptToken += 1
        systemSoundPromptTask = nil
        guard current == nil, systemSoundEnabled else { return }
        systemSoundIdleCheck += 1
        systemSoundIdleUnavailableReason = SystemSoundSwitchOn(authorization: authorization).unavailableReason
    }

    /// 关掉开关时：不再等授权框，拆掉为它保留的采集（还在建的那次建好后直接拆掉）。没在等时什么也不做
    private func cancelSystemSoundPrompt() {
        guard systemSoundPrompt.isPending else { return }
        systemSoundPromptToken += 1
        systemSoundPrompt.cancel()
        systemSoundPromptTask?.cancel()
        systemSoundPromptTask = nil
        systemSound.releaseAuthorizationPromptHold()
        systemSoundLog.info("关掉了开关，不再等授权框")
    }

    private func isCurrentIdleCheck(_ check: Int) -> Bool {
        check == systemSoundIdleCheck && current == nil && systemSoundEnabled
    }

    /// 开始（或重试、重建）系统声音采集的唯一入口：先在子进程里查授权（已知就不查），拒绝就不建；建不起来时
    /// 只记下不可用，麦克风照常录。可用与否变了时记进会议、按需提醒：变为不可用记在 date（这次尝试开始的时刻），
    /// 恢复记在建好的时刻。授权未决定时建立会等用户回答授权框，建好后再查一次：点了允许就按已授权重建一次
    /// （用授权之后建的 tap），点了不允许就停掉、判为没有授权（从这次尝试起算）。
    /// 中途停掉采集（关开关、停止录音、重建）后这次尝试作废，结果不再理会
    private func startSystemSoundCapture(for id: String, at date: Date,
                                         knownAuthorization: SystemSoundAuthorization? = nil) {
        systemSoundAttempt += 1
        let attempt = systemSoundAttempt
        systemSoundAvailability.beginAttempt(at: date)
        // 写盘模块在自己的队列上报分片，切回主线程记进会议
        let onSegment: @Sendable (SystemSoundSegment) -> Void = { [weak self] segment in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.systemSoundSegmentOpened(segment, in: id) }
            }
        }
        Task {
            var known = knownAuthorization
            // 录音前打开开关弹的授权框还在等：等它的结果，不另建一次去弹第二个授权框（ticket 15）。
            // 点了“允许”时保留的采集已经排在后台队列上拆掉，下面按已授权新建，不用再重建一次
            if known == nil, systemSoundPrompt.capturesWait, let prompt = systemSoundPromptTask {
                systemSoundLog.info("授权框还在等用户回答，等它有结果再建系统声音采集")
                let answered = await prompt.value
                guard isCurrentSystemSoundAttempt(attempt, in: id) else { return }
                // 一直没回答（超时）就照常查一次
                if answered != .undetermined { known = answered }
            }
            let authorization: SystemSoundAuthorization
            if let known {
                authorization = known
            } else {
                authorization = await SystemSoundAuthorizationQuery.current()
            }
            guard isCurrentSystemSoundAttempt(attempt, in: id) else { return }
            var builds = false
            updatingSystemSoundAvailability(at: date) {
                builds = systemSoundAvailability.shouldStart(authorization: authorization)
            }
            guard builds else {
                systemSoundLog.error("没有系统录音授权，不采集系统声音")
                return
            }
            do {
                try await systemSound.start(directory: store.systemSoundSegmentsDirectory(id), onSegment: onSegment,
                                            onError: { message in systemSoundLog.error("\(message, privacy: .public)") })
            } catch {
                guard isCurrentSystemSoundAttempt(attempt, in: id) else { return }
                updatingSystemSoundAvailability(at: date) { systemSoundAvailability.startFailed() }
                systemSoundLog.error("系统声音采集没能开始：\(error.localizedDescription, privacy: .public)")
                return
            }
            guard isCurrentSystemSoundAttempt(attempt, in: id) else { return }
            updatingSystemSoundAvailability(at: Date()) {
                isCapturingSystemSound = true
                systemSoundAvailability.started()
            }
            guard systemSoundAvailability.awaitsAuthorization else { return }

            let answered = await SystemSoundAuthorizationQuery.current()
            guard isCurrentSystemSoundAttempt(attempt, in: id) else { return }
            var followUp = SystemSoundAvailability.AuthorizationFollowUp.keep
            updatingSystemSoundAvailability(at: date) {
                followUp = systemSoundAvailability.authorizationResolved(answered)
                if followUp == .stop { stopSystemSoundCaptureKeepingSegments() }
            }
            if followUp == .rebuild {
                systemSoundLog.info("已得到系统录音授权，重建系统声音采集")
                stopSystemSoundCaptureKeepingSegments()
                startSystemSoundCapture(for: id, at: Date(), knownAuthorization: .authorized)
            }
        }
    }

    /// 这次尝试还算数：之后没有停过采集、没有又开始一次，还在录这个会议，开关也还开着
    private func isCurrentSystemSoundAttempt(_ attempt: Int, in id: String) -> Bool {
        attempt == systemSoundAttempt && current?.id == id && current?.isSystemSoundPeriodOpen == true
    }

    /// 停止采集（还在查授权、在建立的那次尝试一起作废），把写盘模块报过、但打开的回调可能还没切回主线程的
    /// 分片补记进 m（已记过的不重复记）。有新记的返回 true，调用方负责写盘
    @discardableResult
    private func stopSystemSoundCapture(into m: inout Meeting) -> Bool {
        systemSoundAttempt += 1
        isCapturingSystemSound = false
        var changed = false
        for segment in systemSound.stop() {
            changed = m.addSystemSoundSegment(segment) || changed
        }
        return changed
    }

    /// 停止采集，把报过的分片补记进正在录的会议并写盘
    private func stopSystemSoundCaptureKeepingSegments() {
        guard var m = current else {
            systemSoundAttempt += 1
            isCapturingSystemSound = false
            systemSound.stop()
            return
        }
        if stopSystemSoundCapture(into: &m) { update(m) }
    }

    /// 唤醒后、格式变了时重建采集：时钟换算按此刻重新锚定，分片接着编号。唤醒后总是重建，不限频
    private func restartSystemSoundCapture() {
        guard let m = current, m.isSystemSoundPeriodOpen else { return }
        stopSystemSoundCaptureKeepingSegments()
        startSystemSoundCapture(for: m.id, at: Date())
    }

    /// tap 格式变了：离上次建立够久就马上重建，否则等 tick 到时补一次（限频，连着变几次只重建一次）
    private func systemSoundFormatChanged() {
        guard systemSound.isRunning, systemSoundAvailability.formatChanged(at: Date()) else { return }
        restartSystemSoundCapture()
    }

    /// 补上之前因为离上次建立太近而推迟的、格式变化触发的重建
    private func rebuildSystemSoundIfFormatChanged() {
        guard systemSound.isRunning, systemSoundAvailability.isFormatRebuildDue(at: Date()) else { return }
        restartSystemSoundCapture()
    }

    /// 运行中聚合设备失效：从失效时刻开一段不可用时段，停掉采集，能重试就马上重建一次。
    /// 重建成功就在建好的时刻结束这段，不发通知；马上重建失败（或不马上重建）才发通知
    private func systemSoundDeviceLost() {
        guard let m = current, m.isSystemSoundPeriodOpen, systemSound.isRunning else { return }
        let lostAt = Date()
        var rebuildsNow = false
        updatingSystemSoundAvailability(at: lostAt) {
            stopSystemSoundCaptureKeepingSegments()
            rebuildsNow = systemSoundAvailability.deviceLost(at: lostAt)
        }
        guard rebuildsNow else { return }
        startSystemSoundCapture(for: m.id, at: lostAt)
    }

    /// 不可用时自动重试：定时（tick）或设备变化时。没有授权的是定时重查授权，查到已授权就重建
    private func retrySystemSoundIfDue(deviceChanged: Bool) {
        let date = Date()
        guard let m = current, m.isSystemSoundPeriodOpen, !systemSound.isRunning,
              systemSoundAvailability.isRetryDue(at: date, deviceChanged: deviceChanged) else { return }
        startSystemSoundCapture(for: m.id, at: date)
    }

    /// 执行 body，可用与否变了时记进会议：变为不可用时在 date 开一段不可用时段，恢复时在 date 结束这段；
    /// 仍不可用、只是原因变了（重试又失败）时不动。date 为 nil 时取 body 执行完的时刻。
    /// 要不要提醒由 `SystemSoundAvailability.takeNotice` 定（每段不可用一次，设备失效马上重建成功的不提醒），
    /// 屏幕可见时发一条无声通知。body 是同步的：跨 await 的一次尝试分几段各包一次
    private func updatingSystemSoundAvailability(at date: Date? = nil, _ body: () -> Void) {
        let wasAvailable = systemSoundAvailability.isAvailable
        body()
        let date = date ?? Date()
        if wasAvailable != systemSoundAvailability.isAvailable, var m = current {
            if let reason = systemSoundAvailability.unavailableReason {
                m.beginSystemSoundUnavailablePeriod(at: date)
                update(m)
                systemSoundLog.error("系统声音不可用：\(String(describing: reason), privacy: .public)")
            } else {
                m.endSystemSoundUnavailablePeriod(at: date)
                update(m)
                systemSoundLog.info("系统声音已恢复")
            }
        }
        if let reason = systemSoundAvailability.takeNotice(), SystemState.hasVisibleScreen {
            Notifier.post(reason.notice.title, reason.notice.body, silent: true)
        }
    }

    /// 系统声音分片打开时记进 meeting.json。按会议 id 找而不是看 current：回调切回主线程时
    /// 录音可能刚停（停止时已补记过，这里不重复记）；会议已经开始整理就不再改它
    private func systemSoundSegmentOpened(_ segment: SystemSoundSegment, in id: String) {
        guard var m = meeting(id), m.status == .recording,
              m.addSystemSoundSegment(segment) else { return }
        update(m)
    }

    /// 录音中的错误除了显示在面板里，还要改菜单栏图标并发通知：
    /// 电平条和计时器照常在走，不提醒的话很难发现其实没在录
    private func recordingFailed(_ message: String) {
        guard isRecording else { return }
        lastError = message
        if !hasRecordingError {
            hasRecordingError = true
            Notifier.post("Faymee 录音出错", message)
        }
    }

    private func levelChanged(_ db: Float) {
        guard isRecording else { return }
        levelDB = db
        silence.micLevel(db, at: Date())
    }

    private func tick() {
        guard let m = current else { return }
        elapsed = Date().timeIntervalSince(m.startedAt)
        // 先切设备再判断合盖：合盖时若有外接麦克风，直接切过去，不产生空白
        reconcileDevice()
        checkLid()
        retrySystemSoundIfDue(deviceChanged: false)
        rebuildSystemSoundIfFormatChanged()

        // 开着系统声音时两路都没声音才算；合盖导致的无声由 checkLid 处理，不重复提醒；看不到屏幕时先不发
        let now = Date()
        silence.systemSoundLevel(systemSound.takeLevel(), at: now)
        let silent = silence.check(at: now, includesSystemSound: isCapturingSystemSound,
                                   canNotify: !isLidGapOpen && SystemState.hasVisibleScreen)
        isSilent = silent.isSilent
        if let notice = silent.notice { Notifier.post(notice) }

        if recorder.secondsSinceLastBuffer > Self.stallAfter,
           Date().timeIntervalSince(lastStallRestart) > Self.stallAfter {
            lastStallRestart = Date()
            recordingFailed("采集停滞，正在重新连接麦克风")
            recorder.restart()
        }
    }

    /// 合盖时内置麦克风被硬件断开，软件无法阻止。这里只负责把这段记下来，并在用户看得到屏幕时告诉他：
    /// 接着外接显示器就立即提示；否则等开盖后再说丢了哪一段
    private func checkLid() {
        guard var m = current else { return }
        let missing = SystemState.isLidClosed == true && recorder.currentDevice?.kind == .builtIn
        if missing, m.openGap == nil {
            m.lidGaps.append(Gap(start: Date(), reason: .lidClosed))
            update(m)
            if SystemState.hasVisibleScreen {
                Notifier.post(LidAlert.closedNotice(capturingSystemSound: isCapturingSystemSound))
            }
        } else if !missing, let i = m.openGap {
            m.lidGaps[i].end = Date()
            update(m)
            // 合盖期间换成外接麦克风的话，用户正看着屏幕，不需要再提醒
            if SystemState.isLidClosed != true {
                Notifier.post(m.lidReopenedNotice(for: m.lidGaps[i]))
            }
        }
    }

    private func refreshDevices() {
        inputDevices = AudioDevices.inputs()
        defaultInputUID = AudioDevices.defaultInput()?.uid
        reconcileDevice()
        retrySystemSoundIfDue(deviceChanged: true)
    }

    /// 录音中，如果按当前选择应该用的麦克风变了（插上外接麦克风、合盖、改了选择），切过去
    private func reconcileDevice() {
        guard isRecording, !recorder.isRetrying else { return }
        let desired = recorder.deviceResolver?() ?? AudioDevices.defaultInput()
        if let desired, desired.uid != recorder.currentDevice?.uid {
            recorder.restart()
        }
    }

    // MARK: - 会中面板、实时字幕

    /// 打开会中面板（菜单栏面板的“会中面板”）。不在录音时什么也不做
    func showLivePanel() {
        guard isRecording else { return }
        livePanel.show()
    }

    /// 录音开始：建好本场的实时字幕（面板第一次看得见时才准备模型），按上次的状态决定是否打开面板
    private func startLiveCaptions() {
        guard let m = current else { return }
        let choice = LiveCaptionEngine.make(selections: modelSelections)
        liveCaptionModelID = choice.modelID
        let finalizer = LiveCaptionFinalizerModel(selected: modelSelections.selected(for: .liveFinalize))
        liveFinalizeModelID = finalizer?.id
        liveCaptions = LiveCaptions(engine: choice.engine, recordingStartedAt: m.startedAt, hotwords: hotwords,
                                    finalizer: finalizer)
        if opensLivePanelOnStart { livePanel.show() }
    }

    /// 录音停止：记下面板开没开（下次录音照样），关掉面板，字幕随之丢弃
    private func stopLiveCaptions() {
        opensLivePanelOnStart = livePanel.isOpen
        livePanel.close()
        liveCaptions = nil
        liveCaptionModelID = nil
        liveFinalizeModelID = nil
    }

    // MARK: - 会中标注

    /// 录音中标记重点（时刻取现在），立即写盘，菜单栏图标闪一下旗子。不在录音时什么也不做，返回 nil。
    /// 快捷键、菜单栏面板、会中面板的“标记重点”都走这里
    @discardableResult
    func addMark() -> Annotation? {
        // 标注加在这份 current 上再保存：录音器也在改同一个会议（分片、合盖空白），不能另读一份写回
        guard var m = current else { return nil }
        let mark = m.addMark(at: Date())
        update(m)
        showsMarkFlag = true
        markFlagReset?.cancel()
        markFlagReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.showsMarkFlag = false
        }
        return mark
    }

    /// 录音中记一笔，立即写盘。time 由调用方给：输入框弹出的时刻，不是回车的时刻。
    /// 文字规整后为空、或不在录音时不记，返回 nil。记一笔的输入框、会中面板的输入框都走这里
    @discardableResult
    func addNote(_ text: String, at time: Date) -> Annotation? {
        guard var m = current, let note = m.addNote(text, at: time) else { return nil }
        update(m)
        return note
    }

    /// 会后修改笔记的文字（转写稿里笔记行的“修改笔记…”）。规整后为空或没变时不改、不写盘。
    /// 改动后纪要按标注哈希提示“会中标注有改动”
    func editNote(_ annotationID: String, to text: String, in meetingID: String) {
        guard var m = meeting(meetingID), m.editNote(annotationID, to: text) else { return }
        update(m)
    }

    /// 会后删除一条标记或笔记（转写稿里旗子、笔记行的右键菜单）
    func deleteAnnotation(_ annotationID: String, in meetingID: String) {
        guard var m = meeting(meetingID), m.deleteAnnotation(annotationID) else { return }
        update(m)
    }

    /// 弹出记一笔的输入框（快捷键 ⌃⌥N、菜单栏面板的“记一笔”）。已经开着时只调到前面
    func beginNote() {
        guard let m = current else { return }
        noteInput.show(stamp: formatDuration(Date().timeIntervalSince(m.startedAt)))
    }

    private func shortcutPressed(_ shortcut: LiveShortcut) {
        guard isRecording else { return }
        switch shortcut {
        case .mark: addMark()
        case .note: beginNote()
        }
    }

    /// 全局快捷键只在录音期间、开关打开时注册。由 current 和开关的 didSet 调用，重复调用不会重复注册
    private func syncHotkeys() {
        let wanted = isRecording && globalShortcutsEnabled
        if wanted, !hotkeys.isRegistered {
            shortcutConflicts = hotkeys.register()
        } else if !wanted, hotkeys.isRegistered {
            hotkeys.unregister()
            shortcutConflicts = []
        }
        if !isRecording, showsMarkFlag {
            markFlagReset?.cancel()
            showsMarkFlag = false
        }
    }

    func refreshSleepState() async {
        sleepDisabled = await SystemState.sleepDisabled()
    }

    // MARK: - 整理

    /// 合并分片为 recording.m4a（有系统声音时另导出 system.m4a）。成功后删除分片；失败则保留分片，可以重试
    func finalize(_ id: String) async {
        guard var m = meeting(id), m.id != current?.id else { return }
        // 整理好就要排队转写：在那之前转写不算空闲。否则标记整理完成、解除暂停的瞬间转写队列是空的，
        // 排队的纪要会抢先开始，新会议的转写稿要等一整场纪要生成完
        transcription.reserve(id)
        defer { transcription.unreserve(id) }
        m.status = .finalizing
        m.error = nil
        update(m)

        let result: Result<FinalizeResult, Error>
        do {
            result = .success(try await Finalizer.export(m, in: store))
        } catch {
            result = .failure(error)
        }

        // 导出期间用户可能改了标题，重新取最新状态
        guard var latest = meeting(id) else { return }
        switch result {
        case let .success(finalized):
            latest.markFinalized(recording: Finalizer.recordingFile, finalized)
            update(latest)
            // 系统声音分片在 segments/system/ 里，一并删除
            try? FileManager.default.removeItem(at: store.segmentsDirectory(id))
            transcription.enqueue(id)
        case let .failure(error):
            latest.status = .failed
            latest.error = error.localizedDescription
            update(latest)
        }
    }

    /// 上次录音被中断（崩溃、强退、断电）或整理到一半：用已落盘的分片补完
    private func recoverInterrupted() async {
        for m in meetings where m.status == .recording || m.status == .finalizing {
            var m = m
            if m.endedAt == nil {
                let lastWrite = store.segmentFiles(m.id).last
                    .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                m.endedAt = lastWrite ?? m.startedAt
            }
            // 仍开着的合盖空白、系统声音时段、不可用时段都结束在估出的录音结束时间
            m.endOpenPeriods(at: m.endedAt ?? m.startedAt)
            update(m)
            await finalize(m.id)
            if meeting(m.id)?.status == .done {
                Notifier.post("已恢复中断的录音", m.title)
            }
        }
    }

    // MARK: - 会议管理

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var m = meeting(id), !title.isEmpty, title != m.title else { return }
        m.title = title
        update(m)
    }

    func trash(_ id: String) {
        guard id != current?.id else { return }
        // 先取消纪要和转写，免得完成时往已删除的目录里写文件。先移出纪要队列：
        // 转写让出引擎时排队的纪要会开始，不能是这场正要删除的会议
        minutes.remove(id)
        transcription.remove(id)
        do {
            try store.trash(id)
            meetings.removeAll { $0.id == id }
        } catch {
            lastError = "删除失败：\(error.localizedDescription)"
            // 会议还在，把被取消的转写（或只区分说话人）放回队列，规则同启动时恢复
            if let m = meeting(id) { transcription.restore([m]) }
            if let status = meeting(id)?.minutes?.status, status == .queued || status == .running {
                minutes.enqueue(id)
            }
        }
    }

    // MARK: - 热词表

    /// 从文件重新载入热词表（启动时、打开热词表窗口时），用户可能用文本编辑器改过。
    /// 还有没写盘的修改时不载入，免得冲掉正在输入的内容
    func reloadHotwords() {
        guard pendingHotwordsSave == nil else { return }
        do {
            let text = try hotwordStore.load()
            savedHotwords = text
            hotwordsText = text
            hotwordsError = nil
        } catch {
            hotwordsError = "读取热词表失败：\(error.localizedDescription)。在这里的修改不会保存，以免覆盖原文件"
        }
    }

    /// 立即写盘还没保存的修改（关窗口、退出 App 时调用）
    func saveHotwords() {
        pendingHotwordsSave?.cancel()
        pendingHotwordsSave = nil
        guard hotwordsText != savedHotwords else { return }
        do {
            try hotwordStore.save(hotwordsText, replacing: savedHotwords)
            savedHotwords = hotwordsText
            hotwordsError = nil
        } catch HotwordStoreError.changedOnDisk {
            hotwordsError = "热词表文件在别处被修改过，这里的修改没有保存。关掉窗口再打开可载入文件里的内容"
        } catch {
            hotwordsError = "保存热词表失败：\(error.localizedDescription)"
        }
    }

    /// 边输入边保存，但不必每个按键都写一次盘：停止输入片刻后再写
    private func scheduleHotwordsSave() {
        pendingHotwordsSave?.cancel()
        pendingHotwordsSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveHotwords()
        }
    }

    // MARK: - 转写

    /// 录音和整理期间暂停转写和纪要，启动恢复完成前也不开始。
    /// 由 meetings、current、launchRecovered 的 didSet 调用，别处不用手动同步。
    /// 同时告诉自动更新现在能不能重启。
    /// 停止录音后到开始整理前，会议还是 .recording（整理在异步任务里才开始），
    /// 也算在内，免得中间空档里转写刚开始就被取消。
    /// 先设转写再设纪要：同时解除时转写先开始（纪要管线另外也会等转写空闲）
    private func syncTranscriptionSuspension() {
        let capturing = isRecording || meetings.contains { $0.status == .recording || $0.status == .finalizing }
        let suspended = !launchRecovered || capturing
        transcription.isSuspended = suspended
        minutes.isSuspended = suspended
        // 转写、纪要被打断后下次启动会续上，不必挡住更新；录音和整理要挡
        updater.isBusy = capturing
    }

    // MARK: - 转写、纪要通知

    /// 用户点了“生成纪要需要先下载模型”或“需要先配置在线模型”的通知，等着打开设置窗口。
    /// MenuBarLabel（App 启动就在）观察它：为 true 时打开设置窗口，再调 `settingsRequestHandled()` 复位。
    /// 用留存的状态而不是一次性回调：点通知可能冷启动 App，那时还没有视图在监听
    private(set) var isSettingsRequested = false

    func requestOpenSettings() { isSettingsRequested = true }

    func settingsRequestHandled() { isSettingsRequested = false }

    private func handleNoticeAction(_ action: MeetingNotice.Action) {
        switch action {
        case .openModelDownload, .openSettings: requestOpenSettings()
        }
    }

    /// 转写成功后按规则自动排队生成纪要；转写完成或失败时发静音通知，录音中不发。
    /// 纪要马上能开始时不发，等纪要完成那一条；在等电源、模型时附说明
    private func transcriptionFinished(_ id: String, _ outcome: TranscriptionOutcome) {
        var followUp = MinutesFollowUp.notQueued
        if case .done = outcome {
            minutes.transcriptionFinished(id)
            followUp = minutes.followUp(for: id)
        }
        guard let m = meeting(id),
              let notice = MeetingNotice.transcription(outcome, meetingTitle: m.title, isRecording: isRecording,
                                                       minutes: followUp)
        else { return }
        Notifier.post(notice)
    }

    /// 纪要生成完成或失败时发静音通知，录音中不发；取消（录音、删除）不回调
    private func minutesFinished(_ id: String, _ outcome: MinutesOutcome) {
        guard let m = meeting(id),
              let notice = MeetingNotice.minutes(outcome, meetingTitle: m.title, isRecording: isRecording)
        else { return }
        Notifier.post(notice)
    }

    // MARK: - 在线模型配置与连接测试

    func testTranscriptionConnection() {
        onlineCoordinator.testTranscriptionConnection()
    }

    func testMinutesConnection() {
        onlineCoordinator.testMinutesConnection()
    }

    func flushOnlineSettingsSync() {
        onlineCoordinator.flushSync()
    }

    func cancelInFlightConnectionTests() {
        onlineCoordinator.cancelInFlightConnectionTests()
    }

    // MARK: - 纪要模型

    /// 正在加载模型或生成纪要时不能删除模型：引擎还在用这个文件。
    /// 被取消的生成退出前也算在用（加载模型时可能一时不理会取消）
    var canDeleteModel: Bool { !minutes.isEngineInUse }

    private func update(_ m: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == m.id }) {
            meetings[i] = m
        }
        if current?.id == m.id {
            current = m
        }
        do {
            try store.save(m)
        } catch {
            lastError = "保存会议信息失败：\(error.localizedDescription)"
        }
    }
}

/// meeting.json 只由 AppModel 写入，转写、纪要管线经这里更新状态
extension AppModel: TranscriptionHost, MinutesHost {
    func setTranscription(_ state: TranscriptionState, for id: String) {
        guard var m = meeting(id) else { return }
        m.transcription = state
        update(m)
    }

    func setDiarization(_ state: DiarizationState?, for id: String) {
        guard var m = meeting(id) else { return }
        m.diarization = state
        update(m)
    }

    func setMinutes(_ state: MinutesState, for id: String) {
        guard var m = meeting(id) else { return }
        m.minutes = state
        update(m)
    }

    func setCorrection(_ state: CorrectionState?, for id: String) {
        guard var m = meeting(id) else { return }
        m.correction = state
        update(m)
    }
}
