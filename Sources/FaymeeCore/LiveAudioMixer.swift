import AVFoundation
import Foundation

/// 实时混音：麦克风和系统声音两路分给实时字幕的音频，按时间对齐混成一路，交给同一个实时字幕会话。
///
/// - 两路各是一个 `LiveAudioTap`：采集线程只拷贝、入队，各自只保留最新约 `capacity` 秒，不阻塞采集线程。
///   转换格式和混音都在取走（`drain`，主线程）时做
/// - 输出跟着麦克风：块数、时刻、格式都和麦克风送来的一样，系统声音只是加进去。
///   系统声音没有数据（没开、没在放声音、还没送到）时按静音处理，麦克风照常输出，不等待
/// - 两路的时刻都是采集线程收到这块的时刻，约等于这块的末尾。系统声音按样本数接着往下排，
///   只在和麦克风差得超过 `tolerance` 时才按时刻重新对齐，收到时刻的抖动不会把对方的话切碎
public final class LiveAudioMixer {
    /// 录音的采集回调写盘之后往这里送一份
    public let microphone: LiveAudioTap
    /// 系统声音的采集回调往这里送一份
    public let systemSound: LiveAudioTap

    /// 系统声音接着往下排的位置和它的收到时刻差得超过这么多，才按时刻重新对齐。
    /// 要大于麦克风一块的时长（16 kHz 耳机上 4096 帧约 0.25 秒）加上取音频的间隔
    public static let tolerance: TimeInterval = 0.5

    public let capacity: TimeInterval

    /// 还没混进麦克风的系统声音：单声道，采样率同麦克风
    private var pending: [Float] = []
    /// pending 第一个样本在麦克风时间线上的时刻。pending 空了也留着，下一块接着排
    private var pendingStart: Date?
    /// 系统声音已经在往麦克风里混、pending 是紧接着混过的部分（不是刚按时刻定下的起点）
    private var flowing = false
    /// 下一块麦克风按样本数推算的开头。收到时刻有抖动，差得不多就用这个，麦克风的时间线不跳
    private var micCursor: Date?
    /// pending 和麦克风时间线的采样率（上一块麦克风的采样率）
    private var rate: Double?
    /// 系统声音和麦克风采样率不同时用的转换器（单声道到单声道）。连着用，块与块之间不出接缝
    private var resampler: AVAudioConverter?

    public init(capacity: TimeInterval = 10) {
        self.capacity = capacity
        microphone = LiveAudioTap(capacity: capacity)
        systemSound = LiveAudioTap(capacity: capacity)
    }

    /// 两路一起开关。关掉时清空已缓存、还没混的音频
    public var isEnabled: Bool {
        get { microphone.isEnabled }
        set {
            microphone.isEnabled = newValue
            systemSound.isEnabled = newValue
            if !newValue { reset() }
        }
    }

    /// 取走两路已缓存的音频，混成一路，按麦克风收到的先后
    public func drain() -> [LiveAudioTap.Chunk] {
        let mics = microphone.drain()
        let systems = systemSound.drain()
        if let last = mics.last, last.buffer.format.sampleRate != rate {
            reset()
            rate = last.buffer.format.sampleRate
        }
        if let rate {
            for chunk in systems { append(chunk, rate: rate) }
        }
        return mics.map(mix)
    }

    // MARK: - 系统声音

    private func append(_ chunk: LiveAudioTap.Chunk, rate: Double) {
        let mono = resample(Self.mono(chunk.buffer), from: chunk.buffer.format.sampleRate, to: rate)
        guard !mono.isEmpty else { return }
        let start = chunk.time.addingTimeInterval(-Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate)
        if let pendingStart {
            let end = pendingStart.addingTimeInterval(Double(pending.count) / rate)
            let gap = start.timeIntervalSince(end)
            if gap > Self.tolerance, !pending.isEmpty {
                // 中间停过一阵（没在放声音时可能没有回调）：补上静音，后面的才落在对的时刻
                pending += [Float](repeating: 0, count: Int((gap * rate).rounded()))
            } else if abs(gap) > Self.tolerance {
                anchor(at: start)
            }
        } else {
            anchor(at: start)
        }
        pending += mono
        // 主线程迟迟没来取、麦克风停着（重建采集）时 pending 会一直长：只留最新的
        let limit = Int(capacity * rate)
        if pending.count > limit { drop(pending.count - limit) }
    }

    /// 和之前的接不上：丢掉没混的，从这一块按它的时刻重新排
    private func anchor(at start: Date) {
        pending.removeAll()
        pendingStart = start
        flowing = false
    }

    // MARK: - 混音

    private func mix(_ chunk: LiveAudioTap.Chunk) -> LiveAudioTap.Chunk {
        let buffer = chunk.buffer
        let format = buffer.format
        guard format.sampleRate == rate else { return chunk }
        let frames = Int(buffer.frameLength)
        let duration = Double(frames) / format.sampleRate
        var start = chunk.time.addingTimeInterval(-duration)
        if let micCursor, abs(start.timeIntervalSince(micCursor)) <= Self.tolerance { start = micCursor }
        micCursor = start.addingTimeInterval(duration)

        guard let pendingStart, !pending.isEmpty, let data = buffer.floatChannelData else { return chunk }
        var offset = Int((pendingStart.timeIntervalSince(start) * format.sampleRate).rounded())
        if offset < 0 {
            // 系统声音比这块麦克风早。正在混的系统声音晚到了一点，就紧接着排，一个样本不丢；
            // 刚开始的、或差得多的，早的那部分已经错过了，丢掉
            if !flowing || Double(-offset) > Self.tolerance * format.sampleRate { drop(-offset) }
            offset = 0
        }
        let count = min(max(frames - offset, 0), pending.count)
        guard count > 0 else { return chunk }
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        for c in 0..<channels {
            let samples = format.isInterleaved ? data[0] + c : data[c]
            for i in 0..<count {
                let j = (offset + i) * stride
                samples[j] = min(max(samples[j] + pending[i], -1), 1)
            }
        }
        drop(count)
        flowing = true
        return chunk
    }

    /// 丢掉 pending 开头的 n 个样本
    private func drop(_ n: Int) {
        let n = min(n, pending.count)
        guard n > 0, let rate, let pendingStart else { return }
        pending.removeFirst(n)
        self.pendingStart = pendingStart.addingTimeInterval(Double(n) / rate)
    }

    private func reset() {
        pending.removeAll()
        pendingStart = nil
        flowing = false
        micCursor = nil
        rate = nil
        resampler = nil
    }

    private func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard source != target, !samples.isEmpty else { return samples }
        let input = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1)!
        if resampler?.inputFormat != input || resampler?.outputFormat != output {
            resampler = AVAudioConverter(from: input, to: output)
        }
        guard let resampler,
              let from = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let to = AVAudioPCMBuffer(pcmFormat: output, frameCapacity:
                  AVAudioFrameCount((Double(samples.count) * target / source).rounded(.up)) + 32)
        else { return [] }
        from.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { from.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        var error: NSError?
        let status = resampler.convert(to: to, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return from
        }
        guard status != .error else { return [] }
        return Array(UnsafeBufferPointer(start: to.floatChannelData![0], count: Int(to.frameLength)))
    }

    /// 各声道取平均成单声道。交错、不交错的 Float32 都可以；别的格式不混（返回空）
    private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        var out = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let samples = format.isInterleaved ? data[0] + c : data[c]
            for i in 0..<frames { out[i] += samples[i * stride] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for i in 0..<frames { out[i] *= scale }
        }
        return out
    }
}
