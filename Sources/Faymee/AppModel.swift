import AVFoundation
import FaymeeCore
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    /// 低于此电平视为没有声音（dBFS）。合盖后内置麦克风被硬件断开，读到的是全 0（-160）
    static let silenceThreshold: Float = -65
    /// 持续无声多久后告警
    static let silenceAlertAfter: TimeInterval = 20
    /// 多久没收到音频数据视为采集停滞，重建引擎
    static let stallAfter: TimeInterval = 5

    // 转写是否暂停由这几项决定，变化时统一重新计算，不靠各处手动同步
    private(set) var meetings: [Meeting] = [] {
        didSet { syncTranscriptionSuspension() }
    }
    private(set) var current: Meeting? {
        didSet { syncTranscriptionSuspension() }
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

    /// 按当前选择和设备状态，开始录音时会用哪个麦克风
    var plannedDevice: AudioInputDevice? {
        inputSelection.resolve(in: inputDevices, lidClosed: SystemState.isLidClosed == true)
            ?? inputDevices.first { $0.uid == defaultInputUID }
    }

    var isRecording: Bool { current != nil }
    /// 正在合盖、用的又是内置麦克风：此刻没有在录到声音
    var isLidGapOpen: Bool { current?.openGap != nil }

    @ObservationIgnored let store = MeetingStore()
    @ObservationIgnored private let hotwordStore = HotwordStore()
    /// 热词表文件里现在的内容（上次读到或存下的），保存前用它核对文件没被别处改过
    @ObservationIgnored private var savedHotwords = ""
    @ObservationIgnored private var pendingHotwordsSave: Task<Void, Never>?
    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var silentSince: Date?
    @ObservationIgnored private var silenceNotified = false
    @ObservationIgnored private var lastStallRestart = Date.distantPast
    /// 启动时的中断恢复和转写恢复是否已完成，之前不开始转写
    @ObservationIgnored private var launchRecovered = false {
        didSet { syncTranscriptionSuspension() }
    }

    /// 会后转写队列。界面直接观察它的 queue / activeID / activity，手动转写调 enqueue；
    /// 会议的转写状态在 meeting.transcription 里，由本类作为 TranscriptionHost 写入
    @ObservationIgnored private(set) lazy var transcription: TranscriptionPipeline = {
        let engine = TranscriptionEngine.make()
        let pipeline = TranscriptionPipeline(store: store, transcriber: engine.transcriber,
                                             engine: engine.name, host: self)
        pipeline.isSuspended = true
        pipeline.hotwords = hotwords
        pipeline.onFinish = { [weak self] in self?.transcriptionFinished($0, $1) }
        return pipeline
    }()

    init() {
        inputSelection = InputSelection(storage: UserDefaults.standard.string(forKey: "inputSelection"))
        selectedDeviceName = UserDefaults.standard.string(forKey: "inputDeviceName")
        meetings = store.loadAll()
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
        Notifier.setUp()
        Task {
            await recoverInterrupted()
            transcription.restore(meetings)
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
        silentSince = nil
        silenceNotified = false
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard var m = current else { return }
        recorder.stop()
        timer?.invalidate()
        timer = nil
        m.endedAt = Date()
        if let i = m.openGap { m.lidGaps[i].end = m.endedAt }
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
        m.segments.append(segment)
        recordingDevice = recorder.currentDevice
        if hasRecordingError {
            hasRecordingError = false
            lastError = nil
        }
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
        if db < Self.silenceThreshold {
            silentSince = silentSince ?? Date()
        } else {
            silentSince = nil
            isSilent = false
            silenceNotified = false
        }
    }

    private func tick() {
        guard let m = current else { return }
        elapsed = Date().timeIntervalSince(m.startedAt)
        // 先切设备再判断合盖：合盖时若有外接麦克风，直接切过去，不产生空白
        reconcileDevice()
        checkLid()

        if let since = silentSince, Date().timeIntervalSince(since) >= Self.silenceAlertAfter {
            isSilent = true
            // 合盖导致的无声由 checkLid 处理，不重复提醒
            if !silenceNotified && !isLidGapOpen {
                silenceNotified = true
                Notifier.post("Faymee 可能没录到声音",
                              "已经 \(Int(Self.silenceAlertAfter)) 秒没有声音了。MacBook 合盖时内置麦克风会被断开，请检查麦克风。")
            }
        }

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
                Notifier.post("内置麦克风已断开", "MacBook 合盖后内置麦克风无法收音，现在没有在录。请打开盖子，或改用外接麦克风。")
            }
        } else if !missing, let i = m.openGap {
            m.lidGaps[i].end = Date()
            update(m)
            // 合盖期间换成外接麦克风的话，用户正看着屏幕，不需要再提醒
            if SystemState.isLidClosed != true {
                Notifier.post("合盖期间没有录到声音", formatTimeRange(m.lidGaps[i]))
            }
        }
    }

    private func refreshDevices() {
        inputDevices = AudioDevices.inputs()
        defaultInputUID = AudioDevices.defaultInput()?.uid
        reconcileDevice()
    }

    /// 录音中，如果按当前选择应该用的麦克风变了（插上外接麦克风、合盖、改了选择），切过去
    private func reconcileDevice() {
        guard isRecording, !recorder.isRetrying else { return }
        let desired = recorder.deviceResolver?() ?? AudioDevices.defaultInput()
        if let desired, desired.uid != recorder.currentDevice?.uid {
            recorder.restart()
        }
    }

    func refreshSleepState() async {
        sleepDisabled = await SystemState.sleepDisabled()
    }

    // MARK: - 整理

    /// 合并分片为 recording.m4a。成功后删除分片；失败则保留分片，可以重试
    func finalize(_ id: String) async {
        guard var m = meeting(id), m.id != current?.id else { return }
        m.status = .finalizing
        m.error = nil
        update(m)

        let output = store.directory(id).appendingPathComponent("recording.m4a")
        let result: Result<FinalizeResult, Error>
        do {
            result = .success(try await Finalizer.export(segments: store.segmentFiles(id), to: output))
        } catch {
            result = .failure(error)
        }

        // 导出期间用户可能改了标题，重新取最新状态
        guard var latest = meeting(id) else { return }
        switch result {
        case let .success(finalized):
            latest.markFinalized(recording: output.lastPathComponent, finalized)
            update(latest)
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
            if let i = m.openGap { m.lidGaps[i].end = m.endedAt }
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
        // 先取消转写，免得转写完成时往已删除的目录里写文件
        transcription.remove(id)
        do {
            try store.trash(id)
            meetings.removeAll { $0.id == id }
        } catch {
            lastError = "删除失败：\(error.localizedDescription)"
            // 会议还在，把被取消的转写放回队列
            if let status = meeting(id)?.transcription?.status, status == .queued || status == .running {
                transcription.enqueue(id)
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

    /// 录音和整理期间暂停转写，启动恢复完成前也不开始。
    /// 由 meetings、current、launchRecovered 的 didSet 调用，别处不用手动同步。
    /// 停止录音后到开始整理前，会议还是 .recording（整理在异步任务里才开始），
    /// 也算在内，免得中间空档里转写刚开始就被取消
    private func syncTranscriptionSuspension() {
        transcription.isSuspended = !launchRecovered || isRecording
            || meetings.contains { $0.status == .recording || $0.status == .finalizing }
    }

    /// 转写完成或失败时发静音通知，录音中不发
    private func transcriptionFinished(_ id: String, _ outcome: TranscriptionOutcome) {
        guard let m = meeting(id),
              let notice = TranscriptionNotice.make(for: outcome, meetingTitle: m.title, isRecording: isRecording)
        else { return }
        Notifier.post(notice.title, notice.body, silent: true)
    }

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

/// meeting.json 只由 AppModel 写入，转写管线经这里更新转写状态
extension AppModel: TranscriptionHost {
    func setTranscription(_ state: TranscriptionState, for id: String) {
        guard var m = meeting(id) else { return }
        m.transcription = state
        update(m)
    }
}
