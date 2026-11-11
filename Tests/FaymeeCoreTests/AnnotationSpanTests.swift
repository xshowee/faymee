import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func segment(_ file: String, startedAt seconds: TimeInterval,
                     offset: TimeInterval? = nil, duration: TimeInterval? = nil) -> Segment {
    Segment(file: file, startedAt: at(seconds), sampleRate: 48000, channels: 1,
            device: "MacBook Pro 麦克风", deviceUID: "BuiltIn", offset: offset, duration: duration)
}

/// 一个从 t0 起、长 total 秒的连续分片
private func meeting(total: TimeInterval = 3600, segments: [Segment]? = nil, gaps: [Gap] = [],
                     annotations: [Annotation]) -> Meeting {
    Meeting(id: "m", title: "会议", startedAt: t0, endedAt: at(total), status: .done,
            segments: segments ?? [segment("0001.caf", startedAt: 0, offset: 0, duration: total)],
            recording: "recording.m4a", duration: total, gaps: gaps, annotations: annotations)
}

private func mark(_ id: String, _ seconds: TimeInterval) -> Annotation {
    Annotation(id: id, at: at(seconds), kind: .mark)
}

private func note(_ id: String, _ seconds: TimeInterval, _ text: String) -> Annotation {
    Annotation(id: id, at: at(seconds), kind: .note, text: text)
}

/// 每 (start, end) 一句，id 依次为 s1、s2……
private func transcript(_ spans: [(TimeInterval, TimeInterval)]) -> Transcript {
    Transcript(engine: "fake/1", createdAt: t0, hotwords: [],
               items: spans.enumerated().map { i, s in
                   .sentence(.init(id: "s\(i + 1)", start: s.0, end: s.1, text: "第\(i + 1)句"))
               })
}

@Suite struct AnnotationSpanTests {
    @Test func 标记为按下前60秒到按下后15秒含有时间重叠的句子() {
        // 标记在 600 秒：区间 540–615。s1 在区间前结束、s4 在区间后开始；s2、s3 与区间重叠
        let m = meeting(annotations: [mark("a1", 600)])
        let t = transcript([(500, 540), (535, 545), (610, 620), (615, 630)])

        #expect(m.annotationSpans(in: t) == [
            AnnotationSpan(kind: .mark, annotationIDs: ["a1"], at: 600, start: 540, end: 615,
                           noteText: nil, sentenceIDs: ["s2", "s3"]),
        ])
    }

    /// 笔记的区间（600–750）比先按的标记（630–705）开始得早，仍按标注时刻排在标记之后；两者重叠也不合并
    @Test func 笔记为弹出前120秒到弹出后30秒按标注时刻排序且不与标记合并() {
        let m = meeting(annotations: [mark("a1", 690), note("a2", 720, "预算 → 老王确认")])
        let t = transcript([(590, 605), (640, 650), (740, 760)])

        #expect(m.annotationSpans(in: t) == [
            AnnotationSpan(kind: .mark, annotationIDs: ["a1"], at: 690, start: 630, end: 705,
                           noteText: nil, sentenceIDs: ["s2"]),
            AnnotationSpan(kind: .note, annotationIDs: ["a2"], at: 720, start: 600, end: 750,
                           noteText: "预算 → 老王确认", sentenceIDs: ["s1", "s2", "s3"]),
        ])
    }

    /// 时钟回拨等情况下列表顺序与时间顺序不一致，仍按时间排
    @Test func 不按列表顺序而按标注时刻排序() {
        let m = meeting(annotations: [note("a1", 900, "后"), mark("a2", 300)])
        #expect(m.annotationSpans(in: transcript([])).map(\.annotationIDs) == [["a2"], ["a1"]])
    }

    @Test func 截到录音范围之内() {
        let m = meeting(total: 900, annotations: [mark("a1", 20), note("a2", 890, "散会")])
        let spans = m.annotationSpans(in: transcript([]))
        #expect(spans.map(\.start) == [0, 770])
        #expect(spans.map(\.end) == [35, 900])
    }

    /// 第二个分片（墙钟 600–620 秒）打不开被整理跳过，第三个分片在录音里紧接第一个（偏移 600）。
    /// 区间两端的墙钟时间分别换算：标记在墙钟 650 秒，区间墙钟 590–665，录音里是 590–645；
    /// 标注时刻 650 → 630
    @Test func 经录音时间线换算含整理时跳过的分片() {
        let m = meeting(total: 900, segments: [
            segment("0001.caf", startedAt: 0, offset: 0, duration: 600),
            segment("0002.caf", startedAt: 600, offset: 600, duration: 0),
            segment("0003.caf", startedAt: 620, offset: 600, duration: 300),
        ], annotations: [mark("a1", 650)])
        let t = transcript([(580, 589), (595, 600), (640, 644), (646, 650)])

        #expect(m.annotationSpans(in: t) == [
            AnnotationSpan(kind: .mark, annotationIDs: ["a1"], at: 630, start: 590, end: 645,
                           noteText: nil, sentenceIDs: ["s2", "s3"]),
        ])
    }

    /// v0.1 整理的旧会议没有分片偏移：按相邻分片开始时间之差近似，偏移钳在录音时长 890 秒之内
    @Test func 旧会议用近似的录音时间线换算() {
        let m = meeting(total: 890, segments: [
            segment("0001.caf", startedAt: 0),
            segment("0002.caf", startedAt: 600),
        ], annotations: [mark("a1", 700), mark("a2", 895)])
        let spans = m.annotationSpans(in: transcript([]))
        #expect(spans.map(\.start) == [640, 835])
        #expect(spans.map(\.end) == [715, 890])
    }

    @Test func 没有分片时没有区间() {
        let m = meeting(segments: [], annotations: [mark("a1", 600)])
        #expect(m.annotationSpans(in: transcript([(590, 600)])).isEmpty)
    }

    /// a1（540–615）与 a2（580–655）重叠，a2 与 a3（650–725）重叠：三个链式合并成 540–725。
    /// a4（725–800）与合并后的区间首尾相接，也合并。a5（900–975）不重叠，单独一段
    @Test func 区间重叠的标记合并成一段() {
        let m = meeting(annotations: [mark("a1", 600), mark("a2", 640), mark("a3", 710),
                                      mark("a4", 785), mark("a5", 960)])
        let t = transcript([(530, 545), (720, 730), (790, 805), (950, 960)])

        #expect(m.annotationSpans(in: t) == [
            AnnotationSpan(kind: .mark, annotationIDs: ["a1", "a2", "a3", "a4"], at: 600, start: 540, end: 800,
                           noteText: nil, sentenceIDs: ["s1", "s2", "s3"]),
            AnnotationSpan(kind: .mark, annotationIDs: ["a5"], at: 960, start: 900, end: 975,
                           noteText: nil, sentenceIDs: ["s4"]),
        ])
    }

    /// 每条笔记有自己的文字要扩写，区间重叠也各自独立；夹在中间的笔记不把两边的标记隔开
    @Test func 笔记不与别的笔记或标记合并() {
        let m = meeting(annotations: [mark("a1", 600), note("a2", 605, "甲"), note("a3", 610, "乙"),
                                      mark("a4", 620)])
        let spans = m.annotationSpans(in: transcript([]))
        #expect(spans.map(\.annotationIDs) == [["a1", "a4"], ["a2"], ["a3"]])
        #expect(spans.map(\.noteText) == [nil, "甲", "乙"])
    }

    /// 合盖空白 300–1500 秒。标记 a1 在 360 秒，区间 300–375 完全落在空白里：s1（270–310）中点在空白外、
    /// 转写稿保留了它，但它与区间重叠的 300–310 也在空白里，不算。标记 a2 在 1510 秒，区间 1450–1525
    /// 一部分在空白外：s2（1495–1505）与区间在空白外重叠了 1500–1505，算
    @Test func 落在合盖空白里的区间没有句子() {
        let m = meeting(gaps: [Gap(start: at(300), end: at(1500), reason: .lidClosed)],
                        annotations: [mark("a1", 360), mark("a2", 1510)])
        let t = transcript([(270, 310), (1495, 1505)])

        let spans = m.annotationSpans(in: t)
        #expect(spans.map(\.annotationIDs) == [["a1"], ["a2"]])
        #expect(spans.map(\.sentenceIDs) == [[], ["s2"]])
    }

    /// 没有句子的区间照样返回：标记不进纪要、笔记未扩写，由纪要生成判断
    @Test func 没有句子的区间照样返回() {
        let m = meeting(annotations: [mark("a1", 600), note("a2", 1800, "预算")])
        let spans = m.annotationSpans(in: transcript([(100, 110)]))
        #expect(spans.map(\.annotationIDs) == [["a1"], ["a2"]])
        #expect(spans.map(\.sentenceIDs) == [[], []])
    }
}
