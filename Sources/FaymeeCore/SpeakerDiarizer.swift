import Foundation

/// 区分说话人引擎，形状仿照 `Transcriber`。管线其余部分（排队、归属到句子、声纹识别、存储、取消）
/// 只依赖这个协议，与具体引擎无关
public protocol SpeakerDiarizer {
    /// 写进转写稿的引擎标识，如 "sherpa-onnx/pyannote"
    var engine: String { get }
    /// 声纹模型标识。声纹库只拿同一模型的声纹比较，换了模型的要重新登记
    var voiceprintModel: String { get }
    /// 准备引擎所需资源，已就绪时立即返回
    func prepare(progress: @escaping (Double) -> Void) async throws
    /// 区分整段录音。speakerCount 为 nil 时由引擎判断人数。需要支持取消
    func diarize(audio: URL, speakerCount: Int?,
                 progress: @escaping (Double) -> Void) async throws -> DiarizationResult
}

/// 引擎输出：说话片段，和每个说话人的声纹（该人全部片段的平均）
public struct DiarizationResult: Hashable, Sendable {
    public var segments: [SpeakerSegment]
    /// 引擎的说话人编号 → 声纹
    public var voiceprints: [Int: Voiceprint]

    public init(segments: [SpeakerSegment], voiceprints: [Int: Voiceprint]) {
        self.segments = segments
        self.voiceprints = voiceprints
    }
}

/// 一段由同一人说的话。start / end 是相对录音文件开头的秒数；speaker 是引擎内的编号，
/// 只在一次区分结果内有意义，与先后无关
public struct SpeakerSegment: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Int

    public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

extension Transcript {
    /// 把区分结果合成到这份转写稿上，只改说话人：句子 id、文字、修改记录、合盖空白都不动；
    /// 原有的说话人、单句修改、名字全部作废（沿用名字是调用方的事）。
    /// - 片段落在合盖空白里的部分不算（合盖时录音是静音）
    /// - 每句归给与它重合最长的说话人，重合按说话人累计；一样长时归给先开口的；不重合的为未知（nil）
    /// - 说话人按在转写稿里第一次开口（第一句归给他的句子）的先后编号为 spk1、spk2……；
    ///   一句都没分到的说话人不进列表
    /// - 发言时长是这个人的片段（去掉空白、合并重叠后）的总长
    public func withSpeakers(_ result: DiarizationResult, engine: String, voiceprintModel: String,
                             createdAt: Date) -> Transcript {
        let gaps = items.compactMap { item -> ClosedRange<TimeInterval>? in
            guard case let .gap(g) = item, g.end > g.start else { return nil }
            return g.start...g.end
        }
        // 引擎编号 → 去掉空白后的片段
        var pieces: [Int: [(start: TimeInterval, end: TimeInterval)]] = [:]
        for s in result.segments where s.end > s.start {
            pieces[s.speaker, default: []] += subtract(gaps, from: (s.start, s.end))
        }
        pieces = pieces.filter { !$0.value.isEmpty }
        // 平票时先开口的优先，固定比较顺序，不依赖字典的遍历顺序
        let labels = pieces.keys.sorted {
            (pieces[$0]!.map(\.start).min()!, $0) < (pieces[$1]!.map(\.start).min()!, $1)
        }

        var numbers: [Int: Int] = [:]
        var out = self
        for (i, item) in items.enumerated() {
            guard case var .sentence(s) = item else { continue }
            var best: (label: Int, overlap: TimeInterval)?
            for label in labels {
                let overlap = pieces[label]!.reduce(0) { $0 + max(0, min($1.end, s.end) - max($1.start, s.start)) }
                if overlap > (best?.overlap ?? 0) { best = (label, overlap) }
            }
            s.speaker = best.map { b in
                let n = numbers[b.label] ?? numbers.count + 1
                numbers[b.label] = n
                return "spk\(n)"
            }
            s.originalSpeaker = nil
            out.items[i] = .sentence(s)
        }

        let speakers = numbers.sorted { $0.value < $1.value }.map { label, n in
            Speaker(id: "spk\(n)", voiceprint: result.voiceprints[label] ?? Voiceprint([]),
                    speechDuration: unionLength(pieces[label]!))
        }
        out.diarization = Diarization(engine: engine, voiceprintModel: voiceprintModel,
                                      speakersCreatedAt: createdAt, speakers: speakers)
        return out
    }
}

/// 区间减去空白，返回剩下的若干段
private func subtract(_ gaps: [ClosedRange<TimeInterval>],
                      from range: (start: TimeInterval, end: TimeInterval)) -> [(start: TimeInterval, end: TimeInterval)] {
    var parts = [range]
    for g in gaps {
        parts = parts.flatMap { p -> [(start: TimeInterval, end: TimeInterval)] in
            guard g.lowerBound < p.end, p.start < g.upperBound else { return [p] }
            return [(p.start, g.lowerBound), (g.upperBound, p.end)].filter { $0.end > $0.start }
        }
    }
    return parts
}

private func unionLength(_ ranges: [(start: TimeInterval, end: TimeInterval)]) -> TimeInterval {
    var total: TimeInterval = 0
    var current: (start: TimeInterval, end: TimeInterval)?
    for r in ranges.sorted(by: { $0.start < $1.start }) {
        if let c = current, r.start <= c.end {
            current = (c.start, max(c.end, r.end))
        } else {
            if let c = current { total += c.end - c.start }
            current = r
        }
    }
    if let c = current { total += c.end - c.start }
    return total
}
