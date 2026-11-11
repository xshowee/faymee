import AVFoundation
import Foundation

/// 录音分给实时字幕的那一路音频：采集线程写盘之后 `push` 一份拷贝，实时字幕在主线程 `drain` 取走。
///
/// 只保留最新约 `capacity` 秒，满了丢最旧的，采集线程只在锁里做几次数组操作，不会被主线程拖住。
/// 关着（不跑实时字幕）时 `push` 什么都不做，不拷贝
public final class LiveAudioTap: @unchecked Sendable {
    public struct Chunk {
        public var buffer: AVAudioPCMBuffer
        /// 采集线程收到这块音频的墙钟时间
        public var time: Date
    }

    /// 最多保留的秒数
    public let capacity: TimeInterval

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var buffered: TimeInterval = 0
    private var enabled = false

    public init(capacity: TimeInterval = 10) {
        self.capacity = capacity
    }

    /// 关掉时清空已缓存的音频
    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            lock.withLock {
                enabled = newValue
                if !newValue { clearLocked() }
            }
        }
    }

    /// 采集线程调用：拷贝一份（采集的缓冲在回调返回后会被复用）。关着时直接返回
    public func push(_ buffer: AVAudioPCMBuffer, at time: Date) {
        guard isEnabled, let copy = Self.copy(buffer) else { return }
        let seconds = Self.seconds(copy)
        lock.withLock {
            guard enabled else { return }
            chunks.append(Chunk(buffer: copy, time: time))
            buffered += seconds
            while buffered > capacity, chunks.count > 1 {
                buffered -= Self.seconds(chunks.removeFirst().buffer)
            }
        }
    }

    /// 取走已缓存的全部音频，按收到的先后
    public func drain() -> [Chunk] {
        lock.withLock {
            let drained = chunks
            clearLocked()
            return drained
        }
    }

    private func clearLocked() {
        chunks.removeAll()
        buffered = 0
    }

    private static func seconds(_ buffer: AVAudioPCMBuffer) -> TimeInterval {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, t) in zip(source, target) {
            guard let from = s.mData, let to = t.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, t.mDataByteSize)))
        }
        return copy
    }
}
