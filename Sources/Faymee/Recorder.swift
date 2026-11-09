import Accelerate
import AVFoundation

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
/// - 分片用 16 位 PCM 的 CAF：进程被强杀后文件仍可读（已验证），不像 m4a 那样缺 moov 就整段报废。
/// - 输入设备变化（插拔麦克风、蓝牙耳机连上）时 AVAudioEngine 会静默停止，
///   这里监听配置变化并重建引擎，从新分片继续录。
/// - 回调都在主线程触发。
final class Recorder {
    static let segmentSeconds: Double = 60

    var onSegment: (@MainActor (Segment) -> Void)?
    var onLevel: (@MainActor (Float) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// 每次（重新）启动采集时调用，决定用哪个麦克风；返回 nil 表示跟随系统默认输入
    var deviceResolver: (() -> AudioInputDevice?)?

    /// 正在录音的设备（跟随系统默认时为当时的默认输入）
    private(set) var currentDevice: AudioInputDevice?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
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
            try startEngine()
        } catch {
            lock.withLock { self.directory = nil }
            throw error
        }
    }

    func stop() {
        teardownEngine()
        lock.withLock { directory = nil }
        currentDevice = nil
    }

    /// 重建采集并开始新分片。设备变化、采集停滞时调用；失败则每秒重试，直到成功或 stop()
    func restart() {
        guard isRunning else { return }
        teardownEngine()
        do {
            try startEngine()
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

    // MARK: - 引擎

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // 只改本 App 的输入设备，不动系统设置
        let chosen = deviceResolver?()
        if let chosen {
            var id = chosen.id
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { throw RecorderError.cannotUseDevice(chosen.name) }
        }
        let device = chosen ?? AudioDevices.defaultInput()
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        currentDevice = device
        lock.withLock { segmentDevice = (device?.name ?? "未知设备", device?.uid) }

        let segment = try lock.withLock { try openSegmentLocked(format: format) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { closeFileLocked(deleteIfEmpty: true) }
            throw error
        }

        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            // 指定设备启动后也可能收到一次配置变化；引擎还在跑、设备也没变就不必重建，避免反复重启
            let desired = self.deviceResolver?() ?? AudioDevices.defaultInput()
            if engine.isRunning && desired?.uid == self.currentDevice?.uid { return }
            self.restart()
        }
        let callback = onSegment
        DispatchQueue.main.async { MainActor.assumeIsolated { callback?(segment) } }
    }

    private func teardownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
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
        let level = Self.levelDB(buffer)
        var newSegment: Segment?
        var errorMessage: String?

        lock.lock()
        lastBufferAt = Date()
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
        lock.unlock()

        let onLevel = onLevel, onSegment = onSegment, onError = onError
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                onLevel?(level)
                if let newSegment { onSegment?(newSegment) }
                if let errorMessage { onError?(errorMessage) }
            }
        }
    }

    private func report(error message: String) {
        let onError = onError
        DispatchQueue.main.async { MainActor.assumeIsolated { onError?(message) } }
    }

    /// 第一个声道的 RMS 电平（dBFS），静音返回 -160
    static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        var meanSquare: Float = 0
        vDSP_measqv(channels[0], 1, &meanSquare, vDSP_Length(buffer.frameLength))
        return meanSquare > 0 ? max(10 * log10(meanSquare), -160) : -160
    }
}
