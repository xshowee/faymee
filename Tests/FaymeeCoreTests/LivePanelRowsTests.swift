import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)

private func caption(_ id: Int, _ start: TimeInterval, _ text: String) -> LiveCaptionLine {
    .sentence(LiveCaption(id: id, start: start, end: start + 3, text: text))
}

private func mark(_ id: String, _ seconds: TimeInterval) -> Annotation {
    Annotation(id: id, at: t0.addingTimeInterval(seconds), kind: .mark)
}

private func note(_ id: String, _ seconds: TimeInterval, _ text: String) -> Annotation {
    Annotation(id: id, at: t0.addingTimeInterval(seconds), kind: .note, text: text)
}

/// 行的简写：字幕原文、分隔行文案、旗子、笔记原文
private func describe(_ rows: [LivePanelRow]) -> [String] {
    rows.map { row in
        switch row.content {
        case .caption(let c): c.text
        case .gap(let g): g.text
        case .mark(let a): "旗子 \(a.id)"
        case .note(let a): "笔记：\(a.text ?? "")"
        }
    }
}

@Suite struct LivePanelRowsTests {
    @Test func 标注按录音里的时间插在字幕之间() {
        let lines = [caption(1, 10, "先说预算。"), caption(2, 20, "月底上线。"), caption(3, 40, "散会。")]
        let annotations = [note("a2", 30, "预算 → 老王确认"), mark("a1", 25)]

        let rows = LivePanelRow.rows(lines: lines, annotations: annotations, recordingStartedAt: t0)

        #expect(describe(rows) == ["先说预算。", "月底上线。", "旗子 a1", "笔记：预算 → 老王确认", "散会。"])
        #expect(rows.map(\.time) == [10, 20, 25, 30, 40])
    }

    /// 标在一句话中间时那句话先开始，旗子排在它后面；同一秒开始的字幕也排在前面
    @Test func 字幕和标注同一时刻时字幕在前() {
        let lines = [caption(1, 25, "这个月底必须上线。")]
        let rows = LivePanelRow.rows(lines: lines, annotations: [mark("a1", 25)], recordingStartedAt: t0)

        #expect(describe(rows) == ["这个月底必须上线。", "旗子 a1"])
    }

    @Test func 暂停期间的标注排在分隔行后面() {
        let gap = LiveCaptionGap(id: 2, start: 60, duration: 180)
        let lines = [caption(1, 50, "合盖前。"), .gap(gap), caption(3, 241, "开盖后。")]
        let rows = LivePanelRow.rows(lines: lines, annotations: [mark("a1", 120)], recordingStartedAt: t0)

        #expect(describe(rows) == ["合盖前。", "中间约 3 分钟没有字幕", "旗子 a1", "开盖后。"])
    }

    /// 设置里关掉实时字幕时面板只显示标注
    @Test func 没有字幕时只有标注_按时间排() {
        let rows = LivePanelRow.rows(lines: [], annotations: [mark("a2", 90), note("a1", 30, "开场")],
                                     recordingStartedAt: t0)

        #expect(describe(rows) == ["笔记：开场", "旗子 a2"])
    }

    /// 字幕只留最近 200 句，更早的标注仍然显示（排在最前），不随字幕丢掉
    @Test func 比留下的字幕还早的标注照常显示在最前() {
        let lines = [caption(301, 3000, "后来的一句。")]
        let rows = LivePanelRow.rows(lines: lines, annotations: [mark("a1", 100)], recordingStartedAt: t0)

        #expect(describe(rows) == ["旗子 a1", "后来的一句。"])
    }

    @Test func 行的标识在字幕和标注之间不重复() {
        let lines = [caption(1, 10, "一。")]
        let rows = LivePanelRow.rows(lines: lines, annotations: [mark("a1", 20)], recordingStartedAt: t0)

        #expect(Set(rows.map(\.id)).count == 2)
    }
}
