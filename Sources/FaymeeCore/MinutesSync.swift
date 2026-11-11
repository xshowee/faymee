import Foundation

/// 纪要与当前转写稿、会议的关系，按 `Minutes.source` 派生，不写盘。几种同时成立时取排在前面的
public enum MinutesSync: Hashable, Sendable {
    case inSync
    /// 转写稿被重新转写：句子 id 已不可信，出处改用生成时记下的 `start`。
    /// 界面提示“转写稿已重新生成，纪要的出处可能不准确”
    case retranscribed
    /// 转写稿的句子被修改：出处仍有效，内容可能过时。界面提示“转写稿有修改”
    case edited
    /// 会中标注改过（改了笔记、删了标注）：出处仍有效，「会中标注」一节可能过时。
    /// 界面提示可以重新生成，不自动重新生成
    case annotationsChanged
}

extension Minutes {
    /// 和当前转写稿、会议比对。`createdAt` 相差 1 秒以内视为同一份：写盘会丢掉小数秒，
    /// 内存里的转写稿和读回的差不到 1 秒；真正的重新转写间隔远大于此。
    /// 会中标注比对 `annotationsHash`（生成时和现在都没有标注时都是 nil）；`meeting` 为 nil 时不比对标注
    public func sync(with transcript: Transcript, meeting: Meeting?) -> MinutesSync {
        if abs(source.transcriptCreatedAt.timeIntervalSince(transcript.createdAt)) >= 1 { return .retranscribed }
        if source.textHash != transcript.textHash { return .edited }
        if let meeting, source.annotationsHash != meeting.annotationsHash { return .annotationsChanged }
        return .inSync
    }
}

/// 出处在当前转写稿里指向哪里：跳到 `time` 播放，转写稿定位到 `sentenceID` 那句
public struct MinutesRefTarget: Hashable, Sendable {
    public var time: TimeInterval
    /// 定位、高亮的句子；转写稿里一句都没有时为 nil
    public var sentenceID: String?
    /// 悬停显示的原句；重新转写后为 nil（显示“转写稿已更新，原句不可用”）
    public var quote: String?

    public init(time: TimeInterval, sentenceID: String?, quote: String?) {
        self.time = time
        self.sentenceID = sentenceID
        self.quote = quote
    }
}

extension Transcript {
    /// 解析出处，规则见 `TranscriptRefLocator.locate`。要解析多个出处时建一个 `TranscriptRefLocator` 复用
    public func locate(_ ref: MinutesRef, sync: MinutesSync) -> MinutesRefTarget {
        TranscriptRefLocator(self).locate(ref, sync: sync)
    }
}

/// 在一份转写稿里解析出处。句子列表和 id 索引建一次，之后每个出处按 id 直接查
struct TranscriptRefLocator: Sendable {
    private let sentences: [TranscriptSentence]
    private let byID: [String: TranscriptSentence]

    init(_ transcript: Transcript) {
        sentences = transcript.sentences
        byID = Dictionary(sentences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 没有重新转写时按 id 找到那句，显示当前文字；
    /// 重新转写后（或 id 找不到时）只认生成时的 `start`：跳到该时间，定位到包含它的句子，
    /// 落在停顿里就取开始时间最近的一句，不显示原句
    func locate(_ ref: MinutesRef, sync: MinutesSync) -> MinutesRefTarget {
        if sync != .retranscribed, let s = byID[ref.id] {
            return MinutesRefTarget(time: s.start, sentenceID: s.id, quote: s.text)
        }
        let nearest = sentences.last { $0.start <= ref.start && ref.start < $0.end }
            ?? sentences.min { abs($0.start - ref.start) < abs($1.start - ref.start) }
        return MinutesRefTarget(time: ref.start, sentenceID: nearest?.id, quote: nil)
    }
}
