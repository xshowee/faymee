import Foundation
import Testing
@testable import FaymeeCore

/// 流式识别按样本数计时，送进去的音频中途丢过一段（分路缓冲满了丢最旧的、引擎积压太多丢最旧的、
/// 录音停滞后重启）时，之后的时间要按每块音频带的墙钟时间对齐，和墙钟记的标记、笔记对得上
@Suite struct StreamingAudioTimelineTests {
    /// 送入 count 块 seconds 秒的音频，从 at 开始首尾相接
    private func feed(_ timeline: inout StreamingAudioTimeline, count: Int, seconds: TimeInterval = 0.1,
                      from at: TimeInterval) {
        for i in 0..<count { timeline.record(duration: seconds, at: at + Double(i) * seconds) }
    }

    @Test func 连续送入时按样本数从第一块的时间算起() {
        var timeline = StreamingAudioTimeline()
        feed(&timeline, count: 100, from: 65)

        #expect(timeline.time(at: 0) == 65)
        #expect(abs(timeline.time(at: 4.25) - 69.25) < 1e-9)
    }

    @Test func 中间丢了一段音频时之后的时间按墙钟对齐_之前的不变() {
        var timeline = StreamingAudioTimeline()
        feed(&timeline, count: 10, seconds: 1, from: 0)
        // 墙钟 10–20 秒的音频没送进识别器
        feed(&timeline, count: 10, seconds: 1, from: 20)

        #expect(timeline.time(at: 5.5) == 5.5)
        #expect(timeline.time(at: 10) == 20)
        #expect(timeline.time(at: 12.5) == 22.5)
    }

    /// 每块的时间取的是采集线程收到它的时刻，前后差一点不算丢了音频，不然时间会一跳一跳
    @Test func 收到时刻的小抖动不重新对齐() {
        var timeline = StreamingAudioTimeline()
        timeline.record(duration: 1, at: 0)
        timeline.record(duration: 1, at: 1.2)
        timeline.record(duration: 1, at: 1.9)
        timeline.record(duration: 1, at: 3.1)

        #expect(timeline.time(at: 2.5) == 2.5)
        #expect(timeline.time(at: 3.5) == 3.5)
    }

    @Test func 丢过几次都各自对齐() {
        var timeline = StreamingAudioTimeline()
        feed(&timeline, count: 5, seconds: 1, from: 0)
        feed(&timeline, count: 5, seconds: 1, from: 100)
        feed(&timeline, count: 5, seconds: 1, from: 300)

        #expect(timeline.time(at: 4) == 4)
        #expect(timeline.time(at: 7) == 102)
        #expect(timeline.time(at: 14.5) == 304.5)
        // 送完之后的时间（引擎收尾时可能略超出）接着最后一段往后算
        #expect(timeline.time(at: 16) == 306)
    }

    @Test func 还没送过音频时原样返回() {
        #expect(StreamingAudioTimeline().time(at: 3) == 3)
    }
}
