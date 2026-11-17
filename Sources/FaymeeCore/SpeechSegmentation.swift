import Foundation

/// 送进识别器的一段音频。下标是 16 kHz 单声道样本数（相对录音开头）
public struct SpeechSegment: Hashable, Sendable {
    /// 送进识别器的样本：说话部分前后补了边（切点处不补）
    public var audio: Range<Int>
    /// 静音切段判定的说话部分（不含补边，在切点处切开）。各段互不重叠，句子时间落在这里面
    public var speech: Range<Int>

    public init(audio: Range<Int>, speech: Range<Int>) {
        self.audio = audio
        self.speech = speech
    }
}

/// 静音切段的后处理（sherpa 整段模型共用）：VAD 说话段前后补边，再把太长的段切开。
///
/// - 补边：VAD 判定的段首段尾常常比真正开口、收声晚一点、早一点（实测 0.1–0.2 秒），前后各多带 0.3 秒避免丢字
/// - 硬上限 10 秒（按补边后送进识别器的长度算）：Fun-ASR-Nano / Qwen3-ASR 的上下文装不下更长的音频，会整段缺字
///   甚至为空；VAD 自带的 `max_speech_duration` 不是硬上限。超过的段在 6–10 秒之间找能量最低的 0.1 秒，
///   从它中点切开，循环到每段 ≤ 10 秒。切点处不补边（补了会让两段重复识别同一个字）
enum SpeechSegmentation {
    static let sampleRate = 16000
    /// 前后补边：0.3 秒
    static let padding = 4800
    /// 每段最长：10 秒
    static let maxLength = 160_000
    /// 切点只在一段开头之后 6 秒到 10 秒之间找
    static let searchFrom = 96000
    /// 找切点时的能量帧：0.1 秒，每 0.05 秒一帧
    static let frame = 1600
    static let hop = 800

    /// VAD 说话段（按时间先后、互不重叠）→ 送进识别器的段
    static func segments(speech: [Range<Int>], samples: [Float]) -> [SpeechSegment] {
        speech.flatMap { raw -> [SpeechSegment] in
            let audio = max(0, raw.lowerBound - padding)..<min(samples.count, raw.upperBound + padding)
            return cut(audio, samples: samples).compactMap { piece in
                let lower = max(piece.lowerBound, raw.lowerBound)
                let upper = min(piece.upperBound, raw.upperBound)
                // 切点落在段尾补边里时（补边常常就是最安静处），最后一小块只有补边，没有说话
                return lower < upper ? SpeechSegment(audio: piece, speech: lower..<upper) : nil
            }
        }
    }

    /// 把一段切成每段 ≤ 10 秒
    private static func cut(_ range: Range<Int>, samples: [Float]) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxLength {
            let cut = quietestPoint(in: (start + searchFrom)..<(start + maxLength), samples: samples)
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<range.upperBound)
        return pieces
    }

    /// 窗口内能量最低的 0.1 秒帧的中点（并列时取最早的）
    private static func quietestPoint(in window: Range<Int>, samples: [Float]) -> Int {
        var best = window.lowerBound
        var bestEnergy = Float.infinity
        var k = window.lowerBound
        while k + frame <= window.upperBound {
            var energy: Float = 0
            for i in k..<(k + frame) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = k
            }
            k += hop
        }
        return best + frame / 2
    }
}
