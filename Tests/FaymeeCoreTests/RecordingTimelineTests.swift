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

private func meeting(_ segments: [Segment], duration: TimeInterval?, endedAt: TimeInterval? = nil) -> Meeting {
    Meeting(id: "m", title: "会议", startedAt: t0, endedAt: endedAt.map(at), status: .done,
            segments: segments, recording: "recording.m4a", duration: duration)
}

@Suite struct RecordingTimelineTests {
    @Test func 连续录音时墙钟时间按分片偏移映射() throws {
        // 两个分片首尾相接：0–600 秒、600–900 秒
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0, offset: 0, duration: 600),
             segment("0002.caf", startedAt: 600, offset: 600, duration: 300)],
            duration: 900)))

        #expect(timeline.offset(at: at(0)) == 0)
        #expect(timeline.offset(at: at(125.5)) == 125.5)
        #expect(timeline.offset(at: at(600)) == 600)
        #expect(timeline.offset(at: at(750)) == 750)
    }

    @Test func 被跳过的分片不占录音时长() throws {
        // 第二个分片打不开被整理跳过：墙钟 600–620 秒在录音里不存在，第三个分片紧接第一个
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0, offset: 0, duration: 600),
             segment("0002.caf", startedAt: 600, offset: 600, duration: 0),
             segment("0003.caf", startedAt: 620, offset: 600, duration: 300)],
            duration: 900)))

        #expect(timeline.offset(at: at(610)) == 600)
        #expect(timeline.offset(at: at(620)) == 600)
        #expect(timeline.offset(at: at(700)) == 680)
    }

    @Test func 分片之间没录到的时段映射到下一分片的起点() throws {
        // 换麦克风重建引擎：第一个分片录到 595 秒，第二个分片 600 秒才开始
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0, offset: 0, duration: 595),
             segment("0002.caf", startedAt: 600, offset: 595, duration: 300)],
            duration: 895)))

        #expect(timeline.offset(at: at(597)) == 595)
        #expect(timeline.offset(at: at(600)) == 595)
        #expect(timeline.offset(at: at(700)) == 695)
    }

    @Test func 录音之前和之后的时间钳到录音首尾() throws {
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 5, offset: 0, duration: 600),
             segment("0002.caf", startedAt: 605, offset: 600, duration: 300)],
            duration: 900)))

        #expect(timeline.offset(at: at(0)) == 0)
        #expect(timeline.offset(at: at(906)) == 900)
        #expect(timeline.offset(at: at(3600)) == 900)
    }

    @Test func 旧会议用相邻分片的开始时间之差近似分片时长() throws {
        // v0.1 整理的会议没有 offset/duration；录音实际 890 秒，比墙钟跨度短了几秒
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0),
             segment("0002.caf", startedAt: 600)],
            duration: 890, endedAt: 900)))

        #expect(timeline.offset(at: at(300)) == 300)
        #expect(timeline.offset(at: at(700)) == 700)
        // 最后一个分片取剩余总时长 290 秒，录音结束之后钳到 890
        #expect(timeline.offset(at: at(895)) == 890)
    }

    @Test func 旧会议分片跨度超过录音时长时偏移不超出录音() throws {
        // 中间分片被跳过等原因，墙钟跨度 1200 秒，录音只有 500 秒
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0),
             segment("0002.caf", startedAt: 600),
             segment("0003.caf", startedAt: 900)],
            duration: 500, endedAt: 1200)))

        #expect(timeline.offset(at: at(400)) == 400)
        #expect(timeline.offset(at: at(700)) == 500)
        #expect(timeline.offset(at: at(1000)) == 500)
    }

    @Test func 合盖空白映射为录音中的区间() throws {
        // 合盖期间内置麦克风断开，录音里是静音；开盖后换回内置麦克风时少录了 5 秒
        var m = meeting(
            [segment("0001.caf", startedAt: 0, offset: 0, duration: 595),
             segment("0002.caf", startedAt: 600, offset: 595, duration: 300)],
            duration: 895, endedAt: 900)
        let gap = Gap(start: at(300), end: at(700), reason: .lidClosed)
        m.lidGaps = [gap]
        let timeline = try #require(RecordingTimeline(m))

        #expect(timeline.range(of: gap) == 300...695)
    }

    @Test func 没有结束时间的空白延续到录音结束() throws {
        let m = meeting([segment("0001.caf", startedAt: 0, offset: 0, duration: 600)],
                        duration: 600, endedAt: 600)
        let timeline = try #require(RecordingTimeline(m))

        #expect(timeline.range(of: Gap(start: at(500), reason: .lidClosed)) == 500...600)
    }

    @Test func 墙钟上的一段音频按分片切开_分片之间和录音首尾之外的部分丢弃() throws {
        // 第一个分片录到 595 秒，第二个分片 600 秒才开始，900 秒结束
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0, offset: 0, duration: 595),
             segment("0002.caf", startedAt: 600, offset: 595, duration: 300)],
            duration: 895)))

        // 墙钟 590–910 秒：590–595 在第一个分片，595–600 没录到，600–900 在第二个分片，900 之后没有录音
        #expect(timeline.pieces(from: at(590), duration: 320) == [
            TimelinePiece(source: 0, offset: 590, duration: 5),
            TimelinePiece(source: 10, offset: 595, duration: 300),
        ])
        // 完全落在断点里
        #expect(timeline.pieces(from: at(596), duration: 3).isEmpty)
    }

    @Test func 分片实际时长长于墙钟间隔时截到下一个分片的起点() throws {
        // 第一个分片有 601 秒音频，第二个分片的墙钟起点却是 600 秒：墙钟 600–601 秒只算在第二个分片里，不摆两次
        let timeline = try #require(RecordingTimeline(meeting(
            [segment("0001.caf", startedAt: 0, offset: 0, duration: 601),
             segment("0002.caf", startedAt: 600, offset: 601, duration: 300)],
            duration: 901)))

        #expect(timeline.pieces(from: at(590), duration: 20) == [
            TimelinePiece(source: 0, offset: 590, duration: 10),
            TimelinePiece(source: 10, offset: 601, duration: 10),
        ])
    }

    @Test func 没有分片时无法映射() {
        #expect(RecordingTimeline(meeting([], duration: nil)) == nil)
    }
}
