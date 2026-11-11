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

private let plainMeeting = Meeting(id: "m1", title: "会议", startedAt: generatedAt.addingTimeInterval(-3600),
                                   status: .done)

/// 一个标记、一条笔记
private func annotatedMeeting() -> Meeting {
    var m = plainMeeting
    m.addMark(at: generatedAt.addingTimeInterval(-3000))
    m.addNote("预算 → 老王确认", at: generatedAt.addingTimeInterval(-2000))
    return m
}

@Suite struct MinutesSyncTests {
    @Test func 同一份转写稿是同步的_写盘丢掉小数秒也不误判为重新转写() throws {
        let saved = try roundTrip(transcript)
        #expect(saved.createdAt != transcript.createdAt)

        #expect(minutes(from: saved).sync(with: saved, meeting: nil) == .inSync)
        // 拿内存里的转写稿生成、和读回的比，或者反过来，都不算重新转写
        #expect(minutes(from: transcript).sync(with: saved, meeting: nil) == .inSync)
        #expect(minutes(from: saved).sync(with: transcript, meeting: nil) == .inSync)
    }

    @Test func 修改句子后派生出转写稿有修改() throws {
        let m = minutes(from: try roundTrip(transcript))
        var edited = try roundTrip(transcript)
        edited.edit(sentence: "s2", to: "支付接口还没有准备好")

        #expect(m.sync(with: edited, meeting: nil) == .edited)
        edited.restore(sentence: "s2")
        #expect(m.sync(with: edited, meeting: nil) == .inSync)
    }

    @Test func 重新转写后派生出已重新转写_哪怕文字没变() throws {
        let m = minutes(from: try roundTrip(transcript))
        var retranscribed = transcript
        retranscribed.createdAt = generatedAt.addingTimeInterval(3600)

        #expect(m.sync(with: retranscribed, meeting: nil) == .retranscribed)
        retranscribed.edit(sentence: "s1", to: "改过的一句")
        #expect(m.sync(with: retranscribed, meeting: nil) == .retranscribed)
    }

    @Test func 会中标注改过后派生出会中标注有改动_改回去又同步() throws {
        var meeting = annotatedMeeting()
        var m = minutes(from: try roundTrip(transcript))
        m.source.annotationsHash = meeting.annotationsHash
        #expect(m.sync(with: transcript, meeting: meeting) == .inSync)

        meeting.editNote("a2", to: "预算 → 老李确认")
        #expect(m.sync(with: transcript, meeting: meeting) == .annotationsChanged)
        meeting.editNote("a2", to: "预算 → 老王确认")
        #expect(m.sync(with: transcript, meeting: meeting) == .inSync)

        meeting.deleteAnnotation("a1")
        #expect(m.sync(with: transcript, meeting: meeting) == .annotationsChanged)
        // 删光了也算有改动：生成时有标注
        meeting.deleteAnnotation("a2")
        #expect(m.sync(with: transcript, meeting: meeting) == .annotationsChanged)
    }

    @Test func 生成时没有标注_会议也没有标注时同步() throws {
        let m = minutes(from: try roundTrip(transcript))
        #expect(m.sync(with: transcript, meeting: plainMeeting) == .inSync)
        // 不知道会议（传 nil）时不判断标注
        var annotated = m
        annotated.source.annotationsHash = annotatedMeeting().annotationsHash
        #expect(annotated.sync(with: transcript, meeting: nil) == .inSync)
    }

    /// 标注写盘读回不改变哈希，不误报
    @Test func 会议写盘读回后标注哈希不变_仍同步() throws {
        let meeting = annotatedMeeting()
        var m = minutes(from: transcript)
        m.source.annotationsHash = meeting.annotationsHash
        let store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.createDirectory(at: store.directory(meeting.id), withIntermediateDirectories: true)
        try store.save(meeting)
        let saved = try #require(store.loadAll().first { $0.id == meeting.id })

        #expect(m.sync(with: transcript, meeting: saved) == .inSync)
    }

    /// 优先级：转写稿已重新生成 > 转写稿有修改 > 会中标注有改动
    @Test func 会中标注有改动排在转写稿有修改和已重新转写之后() throws {
        var meeting = annotatedMeeting()
        var m = minutes(from: try roundTrip(transcript))
        m.source.annotationsHash = meeting.annotationsHash
        meeting.deleteAnnotation("a1")

        var edited = transcript
        edited.edit(sentence: "s2", to: "支付接口还没有准备好")
        #expect(m.sync(with: edited, meeting: meeting) == .edited)
        var retranscribed = transcript
        retranscribed.createdAt = generatedAt.addingTimeInterval(3600)
        #expect(m.sync(with: retranscribed, meeting: meeting) == .retranscribed)
    }

    @Test func 会中标注有改动的提示文字() {
        #expect(MinutesSync.annotationsChanged.notice == "会中标注有改动，可以重新生成纪要")
    }

    @Test func 解析器把会议的标注算进同步状态_标注变了就过期() {
        var meeting = annotatedMeeting()
        var m = minutes(from: transcript)
        m.source.annotationsHash = meeting.annotationsHash
        let resolver = MinutesRefResolver(minutes: m, transcript: transcript, meeting: meeting)
        #expect(resolver.sync == .inSync)

        meeting.deleteAnnotation("a1")
        #expect(!resolver.isCurrent(minutes: m, transcript: transcript, meeting: meeting))
        #expect(resolver.updated(minutes: m, transcript: transcript, meeting: meeting).sync == .annotationsChanged)
        // 会议的其他字段变了不用重建
        var renamed = meeting
        renamed.title = "改个标题"
        let updated = resolver.updated(minutes: m, transcript: transcript, meeting: meeting)
        #expect(updated.isCurrent(minutes: m, transcript: transcript, meeting: renamed))
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
