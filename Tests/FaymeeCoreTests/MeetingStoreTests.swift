import Foundation
import Testing
@testable import FaymeeCore

/// 每个用例一个独立的临时目录作为存储根目录
private func makeStore() -> MeetingStore {
    MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
}

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

@Suite struct MeetingStoreTests {
    @Test func 保存后能原样读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        var m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        m.endedAt = date("2026-11-10T03:00:00Z")
        m.status = .done
        m.segments = [Segment(file: "0001.caf", startedAt: date("2026-11-10T02:00:00Z"),
                              sampleRate: 48000, channels: 1, device: "MacBook Pro 麦克风", deviceUID: "BuiltIn",
                              offset: 0, duration: 3540)]
        m.recording = "recording.m4a"
        m.duration = 3540
        m.lidGaps = [Gap(start: date("2026-11-10T02:10:00Z"), end: date("2026-11-10T02:11:00Z"), reason: .lidClosed)]
        m.transcription = TranscriptionState(status: .failed, error: "录音无法读取")
        try store.save(m)

        #expect(store.loadAll() == [m])
    }

    @Test func 能读取没有gaps字段的旧会议() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // v0.1 早期写出的 meeting.json：没有 gaps，正在录音时也没有 endedAt、recording、duration
        let legacy = """
        {
          "id" : "2026-11-01_09-30-00",
          "segments" : [
            {
              "channels" : 1,
              "device" : "MacBook Pro 麦克风",
              "file" : "0001.caf",
              "sampleRate" : 48000,
              "startedAt" : "2026-11-01T01:30:00Z"
            }
          ],
          "startedAt" : "2026-11-01T01:30:00Z",
          "status" : "recording",
          "title" : "会议 11月1日 09:30"
        }
        """
        let dir = store.directory("2026-11-01_09-30-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("meeting.json"))

        let loaded = try #require(store.loadAll().first)
        #expect(loaded.id == "2026-11-01_09-30-00")
        #expect(loaded.title == "会议 11月1日 09:30")
        #expect(loaded.status == .recording)
        #expect(loaded.startedAt == date("2026-11-01T01:30:00Z"))
        #expect(loaded.endedAt == nil)
        #expect(loaded.segments.map(\.file) == ["0001.caf"])
        #expect(loaded.segments.first?.deviceUID == nil)
        #expect(loaded.segments.first?.offset == nil)
        #expect(loaded.segments.first?.duration == nil)
        #expect(loaded.lidGaps.isEmpty)
        #expect(loaded.openGap == nil)
        #expect(loaded.transcription == nil)
    }

    @Test func 按开始时间从新到旧列出且跳过无法读取的目录() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let older = try store.create(startedAt: date("2026-11-09T02:00:00Z"))
        let newer = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        let middle = try store.create(startedAt: date("2026-11-09T08:00:00Z"))
        // 没有 meeting.json 的目录、内容损坏的 meeting.json 都不应让列表失败
        try FileManager.default.createDirectory(at: store.directory("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directory("broken"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.directory("broken").appendingPathComponent("meeting.json"))

        #expect(store.loadAll().map(\.id) == [newer.id, middle.id, older.id])
    }

    @Test func 转写稿按约定格式写入并能读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))

        #expect(try store.loadTranscript(m.id) == nil)

        let transcript = Transcript(
            engine: "fake/1", createdAt: date("2026-11-10T03:00:00Z"), hotwords: ["飞书", "王总"],
            items: [.sentence(.init(id: "s1", start: 0.48, end: 3.2, text: "我们先过一下上周的待办。")),
                    .gap(.init(start: 600, end: 780.5, reason: .lidClosed)),
                    .sentence(.init(id: "s2", start: 781, end: 783, text: "回来了", original: "灰来了"))])
        try store.saveTranscript(transcript, for: m.id)

        #expect(try store.loadTranscript(m.id) == transcript)

        // 文件格式是 06 编辑、v0.3 摘要引用的契约：kind 区分条目，未修改的句子 original 写成 null
        let url = store.directory(m.id).appendingPathComponent("transcript.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["engine"] as? String == "fake/1")
        #expect(json["createdAt"] as? String == "2026-11-10T03:00:00Z")
        #expect(json["hotwords"] as? [String] == ["飞书", "王总"])
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items.count == 3)
        #expect(items[0]["kind"] as? String == "sentence")
        #expect(items[0]["id"] as? String == "s1")
        #expect(items[0]["start"] as? Double == 0.48)
        #expect(items[0]["end"] as? Double == 3.2)
        #expect(items[0]["text"] as? String == "我们先过一下上周的待办。")
        #expect(items[0].keys.contains("original") && items[0]["original"] is NSNull)
        #expect(items[1]["kind"] as? String == "gap")
        #expect(items[1]["start"] as? Double == 600)
        #expect(items[1]["end"] as? Double == 780.5)
        #expect(items[1]["reason"] as? String == "lidClosed")
        #expect(items[2]["original"] as? String == "灰来了")
    }

    /// 修改后退出 App 再打开（换一个 MeetingStore 实例读同一目录），修改仍在；恢复原文同样持久
    @Test func 编辑后重启仍在() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        var transcript = Transcript(
            engine: "fake/1", createdAt: date("2026-11-10T03:00:00Z"), hotwords: [],
            items: [.sentence(.init(id: "s1", start: 0.48, end: 3.2, text: "灰来了"))])
        try store.saveTranscript(transcript, for: m.id)

        transcript.edit(sentence: "s1", to: "回来了")
        try store.saveTranscript(transcript, for: m.id)
        var reopened = try #require(try MeetingStore(root: store.root).loadTranscript(m.id))
        #expect(reopened.sentences == [.init(id: "s1", start: 0.48, end: 3.2, text: "回来了", original: "灰来了")])

        reopened.restore(sentence: "s1")
        try store.saveTranscript(reopened, for: m.id)
        let restored = try #require(try MeetingStore(root: store.root).loadTranscript(m.id))
        #expect(restored.sentences == [.init(id: "s1", start: 0.48, end: 3.2, text: "灰来了")])
    }
}
