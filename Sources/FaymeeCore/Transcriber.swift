import Foundation

/// 转写引擎。管线其余部分（排队、空白插入、存储、取消、恢复）只依赖这个协议，
/// 与具体引擎无关；长录音的切分（如按静音切段再送入模型）属于引擎实现内部的事
public protocol Transcriber {
    /// 准备引擎所需资源（下载模型等），已就绪时立即返回
    func prepare(progress: @escaping (Double) -> Void) async throws
    /// 转写整段录音，返回带时间的句子。需要支持取消
    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence]
}

/// 引擎输出的一句话。start / end 是相对录音文件开头的秒数，不是墙钟时间
public struct TranscribedSentence: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
