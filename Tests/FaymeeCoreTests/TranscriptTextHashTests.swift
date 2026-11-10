import Foundation
import Testing
@testable import FaymeeCore

private func transcript(_ items: [TranscriptItem]) -> Transcript {
    Transcript(engine: "fake/1", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: items)
}

private let base: [TranscriptItem] = [
    .sentence(.init(id: "s1", start: 0.48, end: 3.2, text: "我们先过一下上周的待办。")),
    .gap(.init(start: 600, end: 780.5, reason: .lidClosed)),
    .sentence(.init(id: "s2", start: 781, end: 783, text: "回来了", original: "灰来了")),
]

/// textHash 写进 minutes.json，之后和当前转写稿比对来判断“句子被修改过”，所以算法一旦发布就不能变
@Suite struct TranscriptTextHashTests {
    /// 期望值用 shell 独立算出：
    /// `printf '2:s136:我们先过一下上周的待办。2:s29:回来了' | shasum -a 256`
    @Test func 按约定字节格式计算SHA256() {
        #expect(transcript(base).textHash
            == "sha256:a0492dd169687542feb1c8b8d1913d6572798122b0efc1c914af7c104cb23b0a")
    }

    @Test func 句子文字变化时变化() {
        var t = transcript(base)
        let before = t.textHash
        t.edit(sentence: "s2", to: "回来啦")
        #expect(t.textHash != before)
    }

    @Test func 句子id变化时变化() {
        var items = base
        items[2] = .sentence(.init(id: "s3", start: 781, end: 783, text: "回来了", original: "灰来了"))
        #expect(transcript(items).textHash != transcript(base).textHash)
    }

    @Test func 空白和时间变化时不变() {
        let moved: [TranscriptItem] = [
            .sentence(.init(id: "s1", start: 1, end: 4, text: "我们先过一下上周的待办。")),
            .sentence(.init(id: "s2", start: 790, end: 792, text: "回来了")),
        ]
        #expect(transcript(moved).textHash == transcript(base).textHash)
    }

    /// 文字在相邻两句之间挪动不能撞出同一个哈希
    @Test func 句子边界移动时变化() {
        let a = transcript([.sentence(.init(id: "s1", start: 0, end: 1, text: "ab")),
                            .sentence(.init(id: "s2", start: 1, end: 2, text: "c"))])
        let b = transcript([.sentence(.init(id: "s1", start: 0, end: 1, text: "a")),
                            .sentence(.init(id: "s2", start: 1, end: 2, text: "bc"))])
        #expect(a.textHash != b.textHash)
    }
}
