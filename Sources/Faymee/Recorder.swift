import Accelerate
import AVFoundation
import CoreAudio
import FaymeeCore

enum RecorderError: LocalizedError {
    case noInputDevice
    case cannotUseDevice(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "没有可用的麦克风"
        case let .cannotUseDevice(name): "无法使用麦克风“\(name)”"
        }
    }
}

/// 从 deviceResolver 指定的麦克风（或系统默认输入）采集音频，按固定时长写成一串 CAF 分片。
///
/// - 直接在麦克风设备上建 IOProc 采集，只碰这一个输入设备。不用 AVAudioEngine：它的 inputNode 和输出共用
///   一个 IO unit，从系统默认输入起步再换设备。默认输入是 AirPods 而用的是别的麦克风时，AirPods 被打开、
///   切成通话模式，引擎随即收到配置变化停下；重建时 inputNode 报的还是 AirPods 的旧格式，`installTap`
///   抛 Objective-C 异常（Swift 接不住，被 AppKit 吞掉后主线程状态坏掉、随后崩溃）。见 issue 16。
/// - 分片用 16 位 PCM 的 CAF：进程被强杀后文件仍可读（已验证），不像 m4a 那样缺 moov 就整段报废。
/// - 设备断开、采样率或流配置变化时重建采集，从新分片继续录；格式变了的数据不写进旧分片。
/// - 设了 `liveTap` 时，每块音频写盘之后再交一份给实时字幕（分路自己拷贝、限长，不阻塞采集线程）。
/// - 回调都在主线程触发；start、stop、restart 都在主线程调用。
final class Recorder {
    static let segmentSeconds: Double = 60

    var onSegment: (@MainActor (Segment) -> Void)?
    var onLevel: (@MainActor (Float) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// 每次（重新）启动采集时调用，决定用哪个麦克风；返回 nil 表示跟随系统默认输入
    var deviceResolver: (() -> AudioInputDevice?)?

    /// 正在录音的设备（跟随系统默认时为当时的默认输入）
    private(set) var currentDevice: AudioInputDevice?

    /// IOProc 在这个队列上执行；停止后在它上面同步一次，确保没有回调还在写分片。同一时刻最多一次采集
    private static let ioQueue = DispatchQueue(label: "faymee.mic-capture", qos: .userInitiated)
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let watch = DeviceWatch()
    private var retryScheduled = false
    /// 麦克风暂时不可用、正在每秒重试
    var isRetrying: Bool { retryScheduled }

    // 以下状态在采集线程和主线程间共享，用 lock 保护
    private let lock = NSLock()
    private var directory: URL?
    private var file: AVAudioFile?
    private var framesInFile: AVAudioFramePosition = 0
    private var nextIndex = 1
    private var writeFailed = false
    private var segmentDevice = (name: "未知设备", uid: String?.none)
    private var lastBufferAt = Date.distantPast
    private var tap: LiveAudioTap?
    /// 电平按约 levelWindow 帧报一次（IOProc 每次只给约 10 ms），不必每块都切回主线程
    private static let levelWindow = 4096
    private var levelSquares: Float = 0
    private var levelFrames = 0

    /// 实时字幕的音频分路。重建采集（切换麦克风）后照常往同一个分路送，格式变化由实时字幕自己处理
    var liveTap: LiveAudioTap? {
        get { lock.withLock { tap } }
        set { lock.withLock { tap = newValue } }
    }

    var isRunning: Bool { lock.withLock { directory != nil } }

    /// 距上次收到音频数据的秒数，用于发现采集停滞
    var secondsSinceLastBuffer: TimeInterval { lock.withLock { Date().timeIntervalSince(lastBufferAt) } }

    func start(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".caf") }.count ?? 0
        lock.withLock {
            self.directory = directory
            nextIndex = existing + 1
            lastBufferAt = Date()
        }
        do {
            try startCapture()
        } catch {
            lock.withLock { self.directory = nil }
            throw error
        }
    }

    func stop() {
        teardownCapture()
        lock.withLock { directory = nil }
        currentDevice = nil
    }

    /// 重建采集并开始新分片。设备变化、采集停滞时调用；失败则每秒重试，直到成功或 stop()
    func restart() {
        guard isRunning else { return }
        teardownCapture()
        do {
            try startCapture()
        } catch {
            guard !retryScheduled else { return }
            report(error: "麦克风不可用，正在重试：\(error.localizedDescription)")
            retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.retryScheduled = false
                self?.restart()
            }
        }
    }

    // MARK: - 采集

    private func startCapture() throws {
        guard let device = deviceResolver?() ?? AudioDevices.defaultInput() else { throw RecorderError.noInputDevice }
        guard let layout = AudioDevices.inputLayout(device.id), let format = layout.makeFormat() else {
            throw RecorderError.cannotUseDevice(device.name)
        }
        currentDevice = device
        lock.withLock {
            segmentDevice = (device.name, device.uid)
            levelSquares = 0
            levelFrames = 0
        }
        let segment = try lock.withLock { try openSegmentLocked(format: format) }

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, Self.ioQueue) { [weak self] _, input, _, _, _ in
            guard let buffer = layout.deinterleave(input, format: format) else { return }
            self?.process(buffer)
        }
        if status == noErr, let procID {
            status = AudioDeviceStart(device.id, procID)
            if status != noErr { AudioDeviceDestroyIOProcID(device.id, procID) }
        }
        guard status == noErr, let procID else {
            lock.withLock { closeFileLocked(deleteIfEmpty: true) }
            currentDevice = nil
            throw RecorderError.cannotUseDevice(device.name)
        }
        deviceID = device.id
        self.procID = procID

        // 设备断开、采样率或流配置变了：按建立时的布局再解读数据就错了，重建
        let id = device.id
        watch.start([(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                     (id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                     (id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
                     (id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)]) { [weak self] in
            guard let self else { return }
            if AudioDevices.isAlive(id), AudioDevices.inputLayout(id) == layout { return }
            self.restart()
        }
        let callback = onSegment
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(segment) } }
    }

    private func teardownCapture() {
        watch.stop()
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            deviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        // 已经派发到队列上的回调执行完，才不会在关掉分片之后又写进来
        Self.ioQueue.sync {}
        lock.withLock { closeFileLocked(deleteIfEmpty: true) }
    }

    // MARK: - 分片（调用方须持有 lock）

    private func openSegmentLocked(format: AVAudioFormat) throws -> Segment {
        closeFileLocked(deleteIfEmpty: false)
        guard let directory else { throw RecorderError.noInputDevice }
        let name = String(format: "%04d.caf", nextIndex)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        nextIndex += 1
        framesInFile = 0
        return Segment(file: name, startedAt: Date(), sampleRate: format.sampleRate,
                       channels: Int(format.channelCount), device: segmentDevice.name, deviceUID: segmentDevice.uid)
    }

    private func closeFileLocked(deleteIfEmpty: Bool) {
        guard let file else { return }
        file.close()
        if deleteIfEmpty && framesInFile == 0 {
            try? FileManager.default.removeItem(at: file.url)
            nextIndex -= 1
        }
        self.file = nil
        framesInFile = 0
    }

    // MARK: - 采集线程

    private func process(_ buffer: AVAudioPCMBuffer) {
        let squares = Self.sumOfSquares(buffer)
        var level: Float?
        var newSegment: Segment?
        var errorMessage: String?

        lock.lock()
        lastBufferAt = Date()
        levelSquares += squares
        levelFrames += Int(buffer.frameLength)
        if levelFrames >= Self.levelWindow {
            level = Self.levelDB(meanSquare: levelSquares / Float(levelFrames))
            levelSquares = 0
            levelFrames = 0
        }
        if let file {
            do {
                try file.write(from: buffer)
                framesInFile += AVAudioFramePosition(buffer.frameLength)
                writeFailed = false
                if Double(framesInFile) >= Self.segmentSeconds * buffer.format.sampleRate {
                    newSegment = try openSegmentLocked(format: buffer.format)
                }
            } catch {
                // 只报一次，避免每个 buffer 都刷一遍错误
                if !writeFailed {
                    writeFailed = true
                    errorMessage = "写入录音失败：\(error.localizedDescription)"
                }
            }
        }
        let tap = tap
        lock.unlock()

        // 写盘之后再分给实时字幕，分路出什么问题都不影响录音
        tap?.push(buffer, at: Date())

        guard level != nil || newSegment != nil || errorMessage != nil else { return }
        let onLevel = onLevel, onSegment = onSegment, onError = onError
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let level { onLevel?(level) }
                if let newSegment { onSegment?(newSegment) }
                if let errorMessage { onError?(errorMessage) }
            }
        }
    }

    private func report(error message: String) {
        let onError = onError
        DispatchQueue.main.async { MainActor.assumeIsolated { onError?(message) } }
    }

    /// 第一个声道的平方和，攒够一个电平窗口再换算成 RMS 电平
    static func sumOfSquares(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        vDSP_svesq(channels[0], 1, &sum, vDSP_Length(buffer.frameLength))
        return sum
    }

    /// RMS 电平（dBFS），静音返回 -160
    static func levelDB(meanSquare: Float) -> Float {
        meanSquare > 0 ? max(10 * log10(meanSquare), -160) : -160
    }
}
