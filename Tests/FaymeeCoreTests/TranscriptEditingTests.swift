import Foundation
import Testing
@testable import FaymeeCore

private func transcript() -> Transcript {
    Transcript(engine: "test", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: [
        .sentence(TranscriptSentence(id: "s1", start: 1.0, end: 3.0, text: "我们先过一下上周的待办")),
        .gap(TranscriptGap(start: 12.0, end: 72.0, reason: .lidClosed)),
        .sentence(TranscriptSentence(id: "s2", start: 73.0, end: 75.0, text: "灰来了，刚才说到哪了")),
    ])
}

private func sentence(_ t: Transcript, _ id: String) -> TranscriptSentence? {
    t.sentences.first { $0.id == id }
}

/// 人工修改句子与恢复原文
@Suite struct 编辑转写稿 {
    @Test func 修改后保存引擎原文且时间不变() {
        var t = transcript()
        let changed = t.edit(sentence: "s2", to: "回来了，刚才说到哪了")

        #expect(changed)

        #expect(sentence(t, "s2") == TranscriptSentence(
            id: "s2", start: 73.0, end: 75.0, text: "回来了，刚才说到哪了", original: "灰来了，刚才说到哪了"))
        #expect(sentence(t, "s1")?.original == nil)
    }

    @Test func 再次修改时原文仍是引擎原文() {
        var t = transcript()
        t.edit(sentence: "s2", to: "回来了，刚才说到哪了")
        t.edit(sentence: "s2", to: "回来了。刚才说到哪了？")

        #expect(sentence(t, "s2")?.text == "回来了。刚才说到哪了？")
        #expect(sentence(t, "s2")?.original == "灰来了，刚才说到哪了")
    }

    @Test func 恢复原文后回到未修改状态() {
        var t = transcript()
        t.edit(sentence: "s2", to: "回来了，刚才说到哪了")
        t.edit(sentence: "s2", to: "回来了。刚才说到哪了？")
        let changed = t.restore(sentence: "s2")

        #expect(changed)
        #expect(t == transcript())
    }

    /// 重新转写前提示“会丢弃 N 处修改”的 N：按被修改的句子数，同一句改几次只算一处
    @Test func 修改处数按被修改的句子计() {
        var t = transcript()
        #expect(t.editCount == 0)

        t.edit(sentence: "s1", to: "我们先过一下上周的代办")
        t.edit(sentence: "s1", to: "我们先过一下上周的待办事项")
        t.edit(sentence: "s2", to: "回来了，刚才说到哪了")
        #expect(t.editCount == 2)

        t.restore(sentence: "s1")
        #expect(t.editCount == 1)
    }

    /// 双击后没改就回车，不算修改，也不必写盘
    @Test func 文字没变不算修改() {
        var t = transcript()
        let changed = t.edit(sentence: "s1", to: "我们先过一下上周的待办")

        #expect(!changed)
        #expect(t.editCount == 0)
    }

    /// 改回和引擎原文一样，就不再显示修改标记
    @Test func 改回引擎原文等于恢复原文() {
        var t = transcript()
        t.edit(sentence: "s2", to: "回来了，刚才说到哪了")
        let changed = t.edit(sentence: "s2", to: "灰来了，刚才说到哪了")

        #expect(changed)
        #expect(t == transcript())
    }

    /// 不支持删句子：清空等于取消。首尾空白和换行去掉，免得粘贴进来的多余字符留在稿里
    @Test func 清空不保存且去掉首尾空白() {
        var t = transcript()
        let cleared = t.edit(sentence: "s1", to: "  \n ")
        #expect(!cleared)
        #expect(t == transcript())

        t.edit(sentence: "s1", to: " 我们先过一下上周的代办\n")
        #expect(sentence(t, "s1")?.text == "我们先过一下上周的代办")
    }

    @Test func 不存在的句子不变() {
        var t = transcript()
        let changed = t.edit(sentence: "s9", to: "随便")
        let restored = t.restore(sentence: "s9")

        #expect(!changed && !restored)
        #expect(t == transcript())
    }

    /// 一句一行：复制全文是一条一行，句子里不能有换行。粘贴进来的换行换成空格
    @Test func 句中换行换成空格() {
        var t = transcript()
        t.edit(sentence: "s1", to: "我们先过一下\n\r\n上周的 todo")

        #expect(sentence(t, "s1")?.text == "我们先过一下 上周的 todo")
    }
}
