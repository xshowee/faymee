import Accelerate
import AVFoundation
import os

/// 系统声音的电平：采集的 IOProc 里每块记一次，主线程每秒取走一次这段时间里的峰值，喂给 `SilenceWatch`。
/// 记的时候只算不拷贝，加锁的时间很短，不阻塞采集线程
public final class SystemSoundLevel: Sendable {
    private let lock = OSAllocatedUnfairLock<Float>(initialState: -160)

    public init() {}

    /// 记一块音频（IOProc 交来的 AudioBufferList，按 format 解读）。各声道分别量 RMS 电平取最大，
    /// 只有一个声道有声音也量得到；交错、不交错两种排列都按 buffer 里实际的声道数走。
    /// 只认 float32，其他格式不记
    public func record(_ bufferList: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard format.commonFormat == .pcmFormatFloat32 else { return }
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard frames > 0 else { continue }
            for c in 0..<channels {
                var meanSquare: Float = 0
                vDSP_measqv(data + c, vDSP_Stride(channels), &meanSquare, vDSP_Length(frames))
                peak = max(peak, meanSquare)
            }
        }
        let db = peak > 0 ? max(10 * log10(peak), -160) : -160
        lock.withLock { $0 = max($0, db) }
    }

    /// 上次取走以来的峰值电平（dBFS），取走后清零；这段时间没有数据为 -160
    public func take() -> Float {
        lock.withLock {
            defer { $0 = -160 }
            return $0
        }
    }
}
