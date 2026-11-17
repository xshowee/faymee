import AVFoundation
import CoreAudio
import FaymeeCore
import os

private let log = Logger(subsystem: "com.faymee.app", category: "system-sound")

enum SystemSoundCaptureError: LocalizedError {
    case coreAudio(step: String, status: OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status): "\(step)失败（\(status)）"
        case .unsupportedFormat: "系统声音的音频格式无法识别"
        }
    }
}

/// 系统声音采集（ADR-0001）：一个全局 process tap（排除 Faymee 自己，回放录音的声音不会录进去），
/// 放进一个只含这个 tap 的私有 aggregate device，由 IOProc 收数据交给写盘模块。
///
/// - 麦克风不在这个 aggregate device 里，仍由 `Recorder` 采集：两者合在一起时，没有声音播放
///   整个设备就不运行，连麦克风也录不到。
/// - 没有声音播放时可能完全没有回调，这是正常的，不当成停滞。
/// - 授权未决定时，系统在给含 tap 的聚合设备建 IOProc（`AudioDeviceCreateIOProcIDWithBlock`）时弹出
///   “系统录音”授权框（说明文字是 Info.plist 的 NSAudioCaptureUsageDescription），这个调用一直阻塞到用户点了
///   按钮；只建 tap 和聚合设备不弹。所以建 tap、聚合设备、IOProc 放在一个串行的后台队列上（同一时刻最多一个
///   在等授权框），其余（启动、监听、停止）在主线程，状态只在主线程读写。
/// - 写盘模块的回调在它自己的队列上，调用方自己切回主线程。
@MainActor
final class SystemSoundCapture {
    /// 私有 aggregate device 的 UID 前缀。它对本进程可见，麦克风列表要把它排除
    nonisolated static let aggregateUIDPrefix = "com.faymee.system-sound."

    /// 建 tap、聚合设备、IOProc（建 IOProc 可能卡在授权框上），拆掉没用上的，都在这个串行队列上
    private nonisolated static let setupQueue = DispatchQueue(label: "faymee.system-sound-setup", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// 每次 start、stop 加一。后台建好时已经变了，说明这次建立已被停掉或换掉：建好的直接拆掉
    private var generation = 0
    private var procID: AudioDeviceIOProcID?
    /// 为授权框保留的 tap、聚合设备和空 IOProc（见 `holdForAuthorizationPrompt`），没有为 nil
    private var promptHold: Created?
    /// 每次开始保留、拆掉加一，用法同 generation，和它分开：start、stop 不影响授权框
    private var promptGeneration = 0
    private var writer: SystemSoundWriter?
    /// IOProc 在这个队列上执行；停止后在它上面同步一次，确保没有回调还在往写盘模块交数据。同一时刻最多一次
    /// 采集在运行（为授权框保留的 IOProc 不启动，不会有回调），所以全类共用一个
    private nonisolated static let ioQueue = DispatchQueue(label: "faymee.system-sound-capture", qos: .userInitiated)
    private let opened = OpenedSegments()
    private let watch = DeviceWatch()
    private let level = SystemSoundLevel()
    private let live = LiveTapSlot()

    /// 实时字幕的系统声音分路，每块音频写盘之后交一份。可以在采集中途设，重建采集后照常往同一个分路送
    var liveTap: LiveAudioTap? {
        get { live.tap }
        set { live.tap = newValue }
    }

    var isRunning: Bool { procID != nil }

    /// 上次取走以来系统声音的峰值电平（dBFS），没有数据为 -160。静音判断每秒取一次
    func takeLevel() -> Float { level.take() }

    /// 运行中聚合设备失效（`kAudioDevicePropertyDeviceIsAlive` 变为 0），在主线程调用。
    /// 采集已经录不到了，调用方停掉它、按“运行中出错”重建
    var onDeviceLost: (@MainActor () -> Void)?
    /// tap 的格式变了（建立时只读一次格式，之后按它解读回调的数据），在主线程调用。
    /// 实测切换输出设备时格式不变；万一变了，调用方重建采集（限频，见 `SystemSoundAvailability.formatChanged`），
    /// 不算不可用
    var onFormatChanged: (@MainActor () -> Void)?

    /// 开始采集，分片写进 directory。建 tap、聚合设备和 IOProc 在后台（授权未决定时建 IOProc 会等用户回答
    /// 授权框），启动、监听回到主线程做。建不起来时抛错，已经建好的部分都拆掉；还没建好就被 stop（或又一次
    /// start）换掉时抛 `CancellationError`，后台建好的直接拆掉。已经在采集时什么也不做
    func start(directory: URL,
               onSegment: @escaping @Sendable (SystemSoundSegment) -> Void,
               onError: @escaping @Sendable (String) -> Void) async throws {
        guard !isRunning else { return }
        generation += 1
        let generation = generation
        // host time 只在同一次采集内有效：每次（重新）建立都按此刻重新锚定
        let opened = opened
        let writer = SystemSoundWriter(directory: directory, clock: .system(),
                                       onSegment: { segment in
                                           opened.append(segment)
                                           onSegment(segment)
                                       },
                                       onError: onError)
        let level = level
        let live = live
        let created = try await Self.onSetupQueue {
            try Self.create(for: "录音") { format in
                Self.ioProc(writer: writer, format: format, level: level, live: live)
            }
        }
        guard generation == self.generation, !isRunning else {
            // IOProc 没启动过，writer 没收到过数据
            Self.setupQueue.async { Self.destroy(created) }
            writer.finish()
            throw CancellationError()
        }
        tapID = created.tapID
        aggregateID = created.aggregateID
        procID = created.procID
        self.writer = writer
        do {
            try commit(format: created.format)
        } catch {
            teardown()
            throw error
        }
    }

    /// 停止采集，写完已收到的音频。返回从上次 stop 以来打开过的全部分片：
    /// 分片打开的回调是异步切回主线程的，可能晚于停止，调用方用这个补记。
    /// 还在后台建立的那次作废（建好后直接拆掉）；不等它，所以不会卡在授权框上
    @discardableResult
    func stop() -> [SystemSoundSegment] {
        generation += 1
        teardown()
        return opened.drain()
    }

    /// 让系统弹出“系统录音”授权框（不在录音时第一次打开开关，spec 用户故事 6）：在后台建一次 tap、只含 tap 的
    /// 聚合设备和一个空的 IOProc（不启动），建好后保留，直到 `releaseAuthorizationPromptHold`。授权框在建 IOProc
    /// 时弹出，只建 tap 和聚合设备不弹；建完马上拆掉的话，授权框还开着，用户之后点的“允许”不会被记住
    /// （ticket 15）。不录、不写盘，和 start / stop 互不影响。
    /// 授权未决定时建 IOProc 一直等到用户回答才返回（在后台队列上等，不卡主线程）。建好并保留时返回 true；
    /// 建不起来（只记日志，开始录音时照常按建立失败处理）、或还没建好就被 release 掉时返回 false
    func holdForAuthorizationPrompt() async -> Bool {
        releaseAuthorizationPromptHold()
        let generation = promptGeneration
        do {
            let created = try await Self.onSetupQueue {
                try Self.create(for: "弹出授权框") { _ in { _, _, _, _, _ in } }
            }
            guard generation == promptGeneration else {
                Self.setupQueue.async { Self.destroy(created) }
                log.info("为弹出授权框建的系统声音采集还没建好就不要了，建好后拆掉")
                return false
            }
            promptHold = created
            log.info("已为弹出授权框建立系统声音采集（含空 IOProc，不启动）并保留")
            return true
        } catch {
            log.error("为弹出授权框建立系统声音采集失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 拆掉为授权框保留的采集（在后台队列上拆，排在之后的建立前面）。还在建的那次作废，建好后直接拆掉。
    /// 没有保留时什么也不做，可以重复调用
    func releaseAuthorizationPromptHold() {
        promptGeneration += 1
        guard let promptHold else { return }
        self.promptHold = nil
        Self.setupQueue.async { Self.destroy(promptHold) }
        log.info("已拆掉为授权框保留的系统声音采集")
    }

    // MARK: - 建立

    /// 后台建好的 tap、聚合设备和 IOProc
    private struct Created: @unchecked Sendable {
        var tapID: AudioObjectID
        var aggregateID: AudioObjectID
        var format: AudioStreamBasicDescription
        var procID: AudioDeviceIOProcID?
    }

    private nonisolated static func onSetupQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            setupQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// 在主线程接着做：启动、监听。出错时已建好的部分由调用方 teardown 拆掉
    private func commit(format asbd: AudioStreamBasicDescription) throws {
        var asbd = asbd
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw SystemSoundCaptureError.unsupportedFormat }
        let starting = Date()
        try Self.check("启动系统声音采集", AudioDeviceStart(aggregateID, procID))
        log.info("启动系统声音采集用了 \(Self.milliseconds(since: starting)) ms")
        watchDevice(format: asbd)
        log.info("系统声音采集已开始：\(format.sampleRate) Hz，\(format.channelCount) 声道")
    }

    /// IOProc 的回调，在 ioQueue 上执行。放在非隔离的静态方法里建，不沾主线程的隔离
    private nonisolated static func ioProc(writer: SystemSoundWriter, format: AVAudioFormat,
                                           level: SystemSoundLevel, live: LiveTapSlot) -> AudioDeviceIOBlock {
        { _, inputData, inputTime, _, _ in
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time()
            writer.push(inputData, format: format, hostTime: hostTime)
            level.record(inputData, format: format)
            // 写盘之后再分给实时字幕（分路自己拷贝、限长）。时刻取收到的时刻，同麦克风
            if let tap = live.tap, tap.isEnabled,
               let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) {
                tap.push(buffer, at: Date())
            }
        }
    }

    /// 在 setupQueue 上建 tap、只含它的私有聚合设备和 IOProc（回调由 block 按 tap 的格式给出，在 ioQueue 上
    /// 执行；这里不启动），带回 tap 的格式。授权未决定时建 IOProc 会一直等到用户回答授权框。
    /// purpose 只用于日志。两步的耗时分开记，在这里量，不含在串行队列上排队的时间（授权框在哪一步等用户回答，
    /// 要靠它在真机上看）。出错时把这里已建好的拆掉再抛错。不碰实例状态
    private nonisolated static func create(for purpose: String,
                                           block: (AVAudioFormat) -> AudioDeviceIOBlock) throws -> Created {
        var created = Created(tapID: AudioObjectID(kAudioObjectUnknown),
                              aggregateID: AudioObjectID(kAudioObjectUnknown), format: AudioStreamBasicDescription())
        do {
            let began = Date()
            try createTapAndAggregate(into: &created)
            log.info("\(purpose, privacy: .public)：建 tap 和聚合设备用了 \(milliseconds(since: began)) ms")
            guard let format = AVAudioFormat(streamDescription: &created.format) else {
                throw SystemSoundCaptureError.unsupportedFormat
            }
            let creatingProc = Date()
            try check("创建系统声音回调",
                      AudioDeviceCreateIOProcIDWithBlock(&created.procID, created.aggregateID, ioQueue, block(format)))
            log.info("\(purpose, privacy: .public)：建 IOProc 用了 \(milliseconds(since: creatingProc)) ms")
            return created
        } catch {
            destroy(created)
            throw error
        }
    }

    private nonisolated static func createTapAndAggregate(into created: inout Created) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try ownProcessObject()])
        description.uuid = UUID()
        description.name = "Faymee 系统声音"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("创建系统声音 tap", AudioHardwareCreateProcessTap(description, &created.tapID))

        try check("读取系统声音格式", getProperty(created.tapID, kAudioTapPropertyFormat, &created.format))
        guard let format = AVAudioFormat(streamDescription: &created.format), format.sampleRate > 0,
              format.channelCount > 0
        else { throw SystemSoundCaptureError.unsupportedFormat }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faymee 系统声音",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // 不加任何 sub device：麦克风不在这里
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check("创建系统声音聚合设备", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &created.aggregateID))
    }

    /// 拆掉建好的 IOProc、聚合设备和 tap，按建立的反序（没建的跳过）。IOProc 没启动过，不用停
    private nonisolated static func destroy(_ created: Created) {
        if let procID = created.procID { AudioDeviceDestroyIOProcID(created.aggregateID, procID) }
        if created.aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(created.aggregateID) }
        if created.tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(created.tapID) }
    }

    /// 按建立的反序拆掉，哪一步没建都跳过
    private func teardown() {
        // 先停掉监听：拆聚合设备本身会让它“失效”，不能当成运行中出错报出去
        watch.stop()
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        // 已经派发到队列上的回调执行完，写盘模块才不会在 finish 之后又收到数据、开出没人记的分片
        Self.ioQueue.sync {}
        writer?.finish()
        writer = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - 失效、格式变化

    private func watchDevice(format: AudioStreamBasicDescription) {
        let tapID = tapID
        let aggregateID = aggregateID
        let properties = [(aggregateID, kAudioDevicePropertyDeviceIsAlive), (tapID, kAudioTapPropertyFormat)]
        watch.start(properties) { [weak self] in
            guard let self else { return }
            var alive = UInt32(1)
            if Self.getProperty(aggregateID, kAudioDevicePropertyDeviceIsAlive, &alive) != noErr || alive == 0 {
                log.error("系统声音聚合设备失效")
                self.onDeviceLost?()
                return
            }
            var current = AudioStreamBasicDescription()
            if Self.getProperty(tapID, kAudioTapPropertyFormat, &current) == noErr,
               current.mSampleRate != format.mSampleRate || current.mChannelsPerFrame != format.mChannelsPerFrame
               || current.mFormatID != format.mFormatID || current.mFormatFlags != format.mFormatFlags
               || current.mBitsPerChannel != format.mBitsPerChannel {
                log.info("系统声音格式变了：\(current.mSampleRate) Hz，\(current.mChannelsPerFrame) 声道")
                self.onFormatChanged?()
            }
        }
    }

    // MARK: - Core Audio

    /// 日志里的耗时（授权框在哪一步等用户回答，要靠它在真机上看）
    private nonisolated static func milliseconds(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    private nonisolated static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw SystemSoundCaptureError.coreAudio(step: step, status: status) }
    }

    /// 本进程的音频进程对象，tap 要排除它
    private nonisolated static func ownProcessObject() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            throw SystemSoundCaptureError.coreAudio(step: "查找 Faymee 的音频进程", status: status)
        }
        return object
    }

    private nonisolated static func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                       _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }
}

/// 写盘模块报过的分片，在写盘队列上追加、在主线程取走
private final class OpenedSegments: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [SystemSoundSegment] = []

    func append(_ segment: SystemSoundSegment) { lock.withLock { segments.append(segment) } }

    func drain() -> [SystemSoundSegment] {
        lock.withLock {
            defer { segments = [] }
            return segments
        }
    }
}

/// 监听这次建立的聚合设备和 tap 的属性变化，在主线程回调。停止后、或已经换了一次建立，
/// 迟到的通知一律丢掉（每次 start 换一代）。和 SystemSoundCapture 一样只在主线程用
private final class DeviceWatch: @unchecked Sendable {
    private var registered: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var generation = 0

    func start(_ properties: [(AudioObjectID, AudioObjectPropertySelector)], onChange: @escaping @MainActor () -> Void) {
        stop()
        let generation = generation
        for (object, selector) in properties {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    onChange()
                }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                registered.append((object, address, block))
            }
        }
    }

    func stop() {
        generation += 1
        for (object, address, block) in registered {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        registered = []
    }
}

/// 实时字幕的分路：主线程设、IOProc 线程读
private final class LiveTapSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: LiveAudioTap?

    var tap: LiveAudioTap? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
