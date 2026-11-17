import Foundation

/// 给大模型类 ASR（Fun-ASR-Nano、Qwen3-ASR）的识别器加上输出防护（`ASROutputGuard`）：
///
/// - 删掉 `[breath]`、`/sil` 这类标记
/// - 失控复读、整段日文、提示词泄漏：这一段从中点切开，前后各多 0.2 秒，分别重转再拼起来（去掉交界处
///   被两半各识别一遍的字）；重转后仍有问题的那一半，复读截到 3 次，日文和泄漏丢掉。只递归一层
/// - 不到 2 秒的段不切（两半会几乎是同一段音频），直接截短或丢掉；只够「末尾 ≥ 5 次」的重复没法核对，
///   当真口吃留着（`ASROutputGuard.salvageWithoutRetry`）
///
/// 会后转写（`SherpaOfflineTranscriber`）和实时字幕定稿都套这一层
public final class GuardedRecognizer: SegmentRecognizer {
    let inner: any SegmentRecognizer

    /// 两半各多带的样本数（0.2 秒）
    static let overlap = 3200
    /// 短于这个长度（2 秒）不切
    static let minSplitLength = 32000

    public init(_ inner: any SegmentRecognizer) {
        self.inner = inner
    }

    public func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        var result = try inner.recognize(samples)
        let text = ASROutputGuard.clean(result.text)
        if text != result.text {
            result = SegmentRecognition(text: text, tokens: nil)
        }
        guard ASROutputGuard.problem(in: text) != nil else { return result }
        guard samples.count >= Self.minSplitLength else {
            return SegmentRecognition(text: ASROutputGuard.salvageWithoutRetry(text), tokens: nil)
        }
        let mid = samples.startIndex + samples.count / 2
        let first = samples[samples.startIndex..<(mid + Self.overlap)]
        let second = samples[(mid - Self.overlap)..<samples.endIndex]
        let texts = try [first, second].map { ASROutputGuard.salvage(ASROutputGuard.clean(try inner.recognize($0).text)) }
        return SegmentRecognition(text: ASROutputGuard.joinHalves(texts[0], texts[1]), tokens: nil)
    }
}
