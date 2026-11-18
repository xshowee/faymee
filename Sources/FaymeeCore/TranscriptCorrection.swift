import Foundation

/// 数字建议（spec「护栏」规则 7）：涉及数字的修改不写进正文，在句子旁显示「可能是『四月』？采纳 / 忽略」（ticket 02）
public struct NumberSuggestion: Codable, Hashable, Sendable {
    /// 句子 id
    public var sentence: String
    /// 句子里的原文，如「十月」
    public var from: String
    /// 建议的写法，如「四月」
    public var to: String
    /// 用户点了「忽略」：不再显示，重新纠错也不再出现同一建议
    public var ignored: Bool

    public init(sentence: String, from: String, to: String, ignored: Bool = false) {
        self.sentence = sentence
        self.from = from
        self.to = to
        self.ignored = ignored
    }
}
