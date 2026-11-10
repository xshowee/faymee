import Foundation
import Testing
@testable import FaymeeCore

private let generatedAt = try! Date("2026-11-10T03:01:00Z", strategy: .iso8601)

/// 转写完成时刻带小数秒，和真实转写一样
private let transcript = Transcript(
    engine: "apple/speechanalyzer", createdAt: generatedAt.addingTimeInterval(0.7), hotwords: [],
    items: [
        .sentence(TranscriptSentence(id: "s1", start: 3.2, end: 6, text: "我们今天讨论发布时间")),
        .gap(TranscriptGap(start: 10, end: 60, reason: .lidClosed)),
        .sentence(TranscriptSentence(id: "s2", start: 60.5, end: 65, text: "支付接口还没准备好")),
        .sentence(TranscriptSentence(id: "s3", start: 80, end: 90, text: "那就推迟一周发布")),
    ])

private func minutes(from t: Transcript) -> Minutes {
    Minutes(model: "fake", template: "general", createdAt: generatedAt,
            source: MinutesSource(transcriptCreatedAt: t.createdAt, textHash: t.textHash), sections: [])
}

/// 写盘再读回：小数秒丢掉
private func roundTrip(_ t: Transcript) throws -> Transcript {
    let store = MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: store.root) }
    try FileManager.default.createDirectory(at: store.directory("m1"), withIntermediateDirectories: true)
    try store.saveTranscript(t, for: "m1")
    return try #require(try store.loadTranscript("m1"))
}

@Suite struct MinutesSyncTests {
    @Test func 同一份转写稿是同步的_写盘丢掉小数秒也不误判为重新转写() throws {
        let saved = try roundTrip(transcript)
        #expect(saved.createdAt != transcript.createdAt)

        #expect(minutes(from: saved).sync(with: saved) == .inSync)
        // 拿内存里的转写稿生成、和读回的比，或者反过来，都不算重新转写
        #expect(minutes(from: transcript).sync(with: saved) == .inSync)
        #expect(minutes(from: saved).sync(with: transcript) == .inSync)
    }

    @Test func 修改句子后派生出转写稿有修改() throws {
        let m = minutes(from: try roundTrip(transcript))
        var edited = try roundTrip(transcript)
        edited.edit(sentence: "s2", to: "支付接口还没有准备好")

        #expect(m.sync(with: edited) == .edited)
        edited.restore(sentence: "s2")
        #expect(m.sync(with: edited) == .inSync)
    }

    @Test func 重新转写后派生出已重新转写_哪怕文字没变() throws {
        let m = minutes(from: try roundTrip(transcript))
        var retranscribed = transcript
        retranscribed.createdAt = generatedAt.addingTimeInterval(3600)

        #expect(m.sync(with: retranscribed) == .retranscribed)
        retranscribed.edit(sentence: "s1", to: "改过的一句")
        #expect(m.sync(with: retranscribed) == .retranscribed)
    }

    @Test func 同步或只改了句子时按id定位出处并显示原句() {
        let ref = MinutesRef(id: "s2", start: 60.5)
        #expect(transcript.locate(ref, sync: .inSync)
            == MinutesRefTarget(time: 60.5, sentenceID: "s2", quote: "支付接口还没准备好"))

        var edited = transcript
        edited.edit(sentence: "s2", to: "支付接口没好")
        #expect(edited.locate(ref, sync: .edited)
            == MinutesRefTarget(time: 60.5, sentenceID: "s2", quote: "支付接口没好"))
    }

    @Test func 重新转写后出处改用start定位到最近的句子_不显示原句() {
        // 重新转写后 s2 指向别的句子：只认生成时记下的 start
        let retranscribed = Transcript(
            engine: "apple/speechanalyzer", createdAt: generatedAt.addingTimeInterval(3600), hotwords: [],
            items: [
                .sentence(TranscriptSentence(id: "s1", start: 2, end: 7, text: "我们今天讨论发布时间")),
                .sentence(TranscriptSentence(id: "s2", start: 30, end: 33, text: "合盖时识别出的别的话")),
                .sentence(TranscriptSentence(id: "s3", start: 59, end: 66, text: "支付接口还没准备好")),
                .sentence(TranscriptSentence(id: "s4", start: 81, end: 90, text: "那就推迟一周发布")),
            ])

        // 落在某句之内
        #expect(retranscribed.locate(MinutesRef(id: "s2", start: 60.5), sync: .retranscribed)
            == MinutesRefTarget(time: 60.5, sentenceID: "s3", quote: nil))
        // 落在两句之间的停顿：开始时间最近的那句
        #expect(retranscribed.locate(MinutesRef(id: "s3", start: 80), sync: .retranscribed)
            == MinutesRefTarget(time: 80, sentenceID: "s4", quote: nil))
        // 转写稿里一句都没有
        let empty = Transcript(engine: "x", createdAt: generatedAt, hotwords: [], items: [])
        #expect(empty.locate(MinutesRef(id: "s1", start: 3.2), sync: .retranscribed)
            == MinutesRefTarget(time: 3.2, sentenceID: nil, quote: nil))
    }
}
