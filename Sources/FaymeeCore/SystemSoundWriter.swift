import AVFoundation
import Darwin
import Foundation

/// host time（`mach_absolute_time` 的 tick）与秒、墙钟的换算。只在同一次采集内使用，不跨重启、不持久化
public struct HostClock: Sendable {
    public var ticksPerSecond: Double
    /// 与 referenceDate 同一时刻的 host time
    public var referenceHostTime: UInt64
    public var referenceDate: Date

    public init(ticksPerSecond: Double, referenceHostTime: UInt64, referenceDate: Date) {
        self.ticksPerSecond = ticksPerSecond
        self.referenceHostTime = referenceHostTime
        self.referenceDate = referenceDate
    }

    /// 以此刻为锚点的系统时钟。Apple Silicon 上 tick 不是纳秒，要按 timebase 换算
    public static func system() -> HostClock {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        return HostClock(ticksPerSecond: ticksPerSecond, referenceHostTime: mach_absolute_time(), referenceDate: Date())
    }

    /// from 到 to 的秒数，to 更早时为负
    public func seconds(from: UInt64, to: UInt64) -> TimeInterval {
        to >= from ? Double(to - from) / ticksPerSecond : -Double(from - to) / ticksPerSecond
    }

    public func date(forHostTime hostTime: UInt64) -> Date {
        referenceDate.addingTimeInterval(seconds(from: referenceHostTime, to: hostTime))
    }
}

/// 系统声音写盘：采集回调交来带 host time 的音频块，这里按约 `segmentSeconds` 一片写成 CAF 分片。
///
/// - 采集线程的 `push` 只拷贝、入队，写盘在自己的串行队列上做，不阻塞采集线程。
/// - 分片在第一块音频到来时才打开，墙钟起点是这一块第一帧的时间；打开时调 `onSegment`，
///   由 App 模型写进会议数据。
/// - 分片 CAF 和麦克风分片一样用 16 位 PCM，进程被强杀后仍可读。
/// - `onSegment`、`onError` 在写盘队列上调用，需要主线程的调用方自己切过去。
public final class SystemSoundWriter: @unchecked Sendable {
    /// 一个系统声音分片
    public struct Segment: Hashable, Sendable {
        public var file: String
        /// 第一帧的墙钟时间
        public var startedAt: Date
        public var sampleRate: Double
        public var channels: Int

        public init(file: String, startedAt: Date, sampleRate: Double, channels: Int) {
            self.file = file
            self.startedAt = startedAt
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public let directory: URL
    public let segmentSeconds: TimeInterval
    /// 回调间隔的抖动在这个范围内不补静音
    public let jitterTolerance: TimeInterval
    private let clock: HostClock
    private let onSegment: @Sendable (Segment) -> Void
    private let onError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "faymee.system-sound-writer")

    // 以下只在 queue 上访问
    private var file: AVAudioFile?
    /// 下一个分片的编号，第一次开分片时按目录里已有的分片接着排
    private var nextIndex: Int?
    /// 当前分片第一帧的 host time
    private var segmentStart: UInt64 = 0
    private var framesInFile: AVAudioFramePosition = 0
    private var writeFailed = false

    public init(directory: URL, clock: HostClock,
                segmentSeconds: TimeInterval = 60, jitterTolerance: TimeInterval = 0.02,
                onSegment: @escaping @Sendable (Segment) -> Void,
                onError: @escaping @Sendable (String) -> Void) {
        self.directory = directory
        self.clock = clock
        self.segmentSeconds = segmentSeconds
        self.jitterTolerance = jitterTolerance
        self.onSegment = onSegment
        self.onError = onError
    }

    /// 采集线程调用。hostTime 是这一块第一帧的 host time。只拷贝（采集的缓冲在回调返回后会被复用）、入队
    public func push(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let copy = buffer.copied() else { return }
        queue.async { self.write(copy, hostTime: hostTime) }
    }

    /// IOProc 里调用：把采集交来的 AudioBufferList 按 format 解读（帧数由字节数决定），拷贝、入队
    public func push(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat, hostTime: UInt64) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil)
        else { return }
        push(buffer, hostTime: hostTime)
    }

    /// 写完已入队的音频并关掉当前分片。之后不应再 push
    public func finish() {
        queue.sync { closeSegment() }
    }

    // MARK: - 写盘队列

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let rate = buffer.format.sampleRate
        do {
            if let file {
                // 这一块在本片里应有的位置按“本片第一帧的 host time”算，而不是相对上一块，片内位置才不会越积越偏
                let position = AVAudioFramePosition((clock.seconds(from: segmentStart, to: hostTime) * rate).rounded())
                if !Self.sameFormat(file.processingFormat, buffer.format) {
                    // 换了输出设备，格式变了：一个分片只有一种格式
                    closeSegment()
                } else if Double(position) >= segmentSeconds * rate {
                    // 空洞长到越过本片末尾：不写长串的零，关掉本片，从这一块开新片、记新的墙钟起点
                    closeSegment()
                } else if Double(position - framesInFile) > jitterTolerance * rate {
                    // 缺口超过容差才补静音；容差内的抖动（早到或晚到）照原样接着写
                    try writeSilence(frames: position - framesInFile, format: buffer.format, to: file)
                }
            }
            if file == nil { try open(format: buffer.format, hostTime: hostTime) }
            guard let file else { return }
            try file.write(from: buffer)
            framesInFile += AVAudioFramePosition(buffer.frameLength)
            // 满一片就关掉；下一片等下一块到来时再开，起点记那一块第一帧的时间
            if Double(framesInFile) >= segmentSeconds * rate { closeSegment() }
            writeFailed = false
        } catch {
            // 只报一次，避免每块都刷一遍错误；下一块照常再试。麦克风录音不受影响
            guard !writeFailed else { return }
            writeFailed = true
            onError("写入系统声音失败：\(error.localizedDescription)")
        }
    }

    /// 目录里已有分片的最大编号，没有为 0
    private static func lastIndex(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".caf") }.compactMap { Int($0.dropLast(4)) }.max() ?? 0
    }

    private static func sameFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    private func closeSegment() {
        file?.close()
        file = nil
        framesInFile = 0
    }

    private func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat, to file: AVAudioFile) throws {
        // 每次最多一秒，不为长空洞分配一大块内存
        let step = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { return }
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, AVAudioFramePosition(step)))
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for b in buffers { if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) } }
            try file.write(from: silence)
            framesInFile += AVAudioFramePosition(silence.frameLength)
            remaining -= AVAudioFramePosition(silence.frameLength)
        }
    }

    private func open(format: AVAudioFormat, hostTime: UInt64) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = nextIndex ?? Self.lastIndex(in: directory) + 1
        let name = String(format: "%04d.caf", index)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // 处理格式跟随交来的音频（process tap 通常是交错的 32 位浮点），写入时不用再转换
        file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        nextIndex = index + 1
        segmentStart = hostTime
        framesInFile = 0
        onSegment(Segment(file: name, startedAt: clock.date(forHostTime: hostTime),
                          sampleRate: format.sampleRate, channels: Int(format.channelCount)))
    }
}
