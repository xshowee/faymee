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
        m.minutes = MinutesState(status: .failed, error: "模型输出无法解析")
        m.diarization = DiarizationState(status: .failed, error: "区分说话人引擎无法加载")
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
        #expect(loaded.minutes == nil)
    }

    /// v0.2 写出的 meeting.json：已转写，没有 minutes 字段
    @Test func 能读取没有minutes字段的v02会议() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let legacy = """
        {
          "id" : "2026-11-05_14-00-00",
          "recording" : "recording.m4a",
          "segments" : [],
          "startedAt" : "2026-11-05T06:00:00Z",
          "status" : "done",
          "title" : "会议 11月5日 14:00",
          "transcription" : { "status" : "done" }
        }
        """
        let dir = store.directory("2026-11-05_14-00-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("meeting.json"))

        let loaded = try #require(store.loadAll().first)
        #expect(loaded.transcription == TranscriptionState(status: .done))
        #expect(loaded.minutes == nil)
        #expect(loaded.diarization == nil)
    }

    @Test func 说话人状态按约定字段写入() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        #expect(m.diarization == nil)
        m.diarization = DiarizationState(status: .running)
        try store.save(m)

        let url = store.directory(m.id).appendingPathComponent("meeting.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let diarization = try #require(json["diarization"] as? [String: Any])
        #expect(diarization["status"] as? String == "running")
        #expect(store.loadAll().first?.diarization == DiarizationState(status: .running))
    }

    @Test func 纪要状态按约定字段写入() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        m.minutes = MinutesState(status: .queued)
        try store.save(m)

        let url = store.directory(m.id).appendingPathComponent("meeting.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let minutes = try #require(json["minutes"] as? [String: Any])
        #expect(minutes["status"] as? String == "queued")
        #expect(store.loadAll().first?.minutes == MinutesState(status: .queued))
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

    /// v0.3 写出的 transcript.json：没有说话人信息，句子没有 speaker
    @Test func 能读取没有说话人字段的v03转写稿() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        let legacy = """
        {
          "createdAt" : "2026-11-10T03:00:00Z",
          "engine" : "apple/speechanalyzer",
          "hotwords" : [],
          "items" : [
            { "end" : 3.2, "id" : "s1", "kind" : "sentence", "original" : null, "start" : 0.48, "text" : "开始吧" },
            { "end" : 780.5, "kind" : "gap", "reason" : "lidClosed", "start" : 600 }
          ],
          "version" : 1
        }
        """
        try Data(legacy.utf8).write(to: store.directory(m.id).appendingPathComponent("transcript.json"))

        let loaded = try #require(try store.loadTranscript(m.id))
        #expect(loaded.diarization == nil)
        #expect(loaded.speakers.isEmpty)
        #expect(loaded.speakersCreatedAt == nil)
        #expect(loaded.sentences == [.init(id: "s1", start: 0.48, end: 3.2, text: "开始吧")])
        #expect(loaded.sentences.first?.speaker == nil)
        #expect(loaded.sentences.first?.originalSpeaker == nil)
    }

    @Test func 说话人按约定格式写入并能读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        let transcript = Transcript(
            engine: "fake/1", createdAt: date("2026-11-10T03:00:00Z"), hotwords: [],
            items: [.sentence(.init(id: "s1", start: 0, end: 2, text: "王总你怎么看", speaker: "spk1")),
                    .sentence(.init(id: "s2", start: 2, end: 4, text: "我觉得可以", speaker: "spk1",
                                    originalSpeaker: .init(speaker: "spk2"))),
                    .sentence(.init(id: "s3", start: 4, end: 5, text: "嗯", originalSpeaker: .init(speaker: nil))),
                    .sentence(.init(id: "s4", start: 5, end: 6, text: "（咳嗽）"))],
            diarization: Diarization(
                engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1",
                speakersCreatedAt: date("2026-11-10T03:01:00Z"),
                speakers: [Speaker(id: "spk1", name: "张三", nameSource: .voiceprint, personID: "p1",
                                   voiceprint: Voiceprint([0.5, -1.25, 3.0]), speechDuration: 12.5),
                           Speaker(id: "spk2", voiceprint: Voiceprint([1, 0, 0]), speechDuration: 3)]))
        try store.saveTranscript(transcript, for: m.id)

        #expect(try MeetingStore(root: store.root).loadTranscript(m.id) == transcript)

        let url = store.directory(m.id).appendingPathComponent("transcript.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let diarization = try #require(json["diarization"] as? [String: Any])
        #expect(diarization["engine"] as? String == "fake-diarizer/1")
        #expect(diarization["voiceprintModel"] as? String == "fake-embedding/1")
        #expect(diarization["speakersCreatedAt"] as? String == "2026-11-10T03:01:00Z")
        let speakers = try #require(diarization["speakers"] as? [[String: Any]])
        #expect(speakers.count == 2)
        #expect(speakers[0]["id"] as? String == "spk1")
        #expect(speakers[0]["name"] as? String == "张三")
        #expect(speakers[0]["nameSource"] as? String == "voiceprint")
        #expect(speakers[0]["personId"] as? String == "p1")
        // float32 小端的 base64，期望值用 python 独立算出：
        // base64.b64encode(struct.pack('<3f', 0.5, -1.25, 3.0))
        #expect(speakers[0]["voiceprint"] as? String == "AAAAPwAAoL8AAEBA")
        #expect(speakers[0]["speechDuration"] as? Double == 12.5)
        #expect(speakers[1]["name"] == nil)
        #expect(speakers[1]["nameSource"] == nil)

        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items[0]["speaker"] as? String == "spk1")
        #expect(items[0]["originalSpeaker"] == nil)
        #expect(items[1]["speaker"] as? String == "spk1")
        #expect((items[1]["originalSpeaker"] as? [String: Any])?["speaker"] as? String == "spk2")
        // 改过说话人、区分结果原本是“未知”：原值写成 null，与“没改过”（没有 originalSpeaker）区分开
        #expect(items[2]["speaker"] == nil)
        let unknown = try #require(items[2]["originalSpeaker"] as? [String: Any])
        #expect(unknown.keys.contains("speaker") && unknown["speaker"] is NSNull)
        #expect(items[3]["speaker"] == nil)
        #expect(items[3]["originalSpeaker"] == nil)
    }

    /// 管线在主线程上只读生成时间和有没有说话人，生成时间与完整读出的相等（据此判断期间有没有被重新转写）
    @Test func 只读转写稿摘要() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        #expect(!store.hasTranscript(m.id))
        #expect(try store.loadTranscriptSummary(m.id) == nil)

        var transcript = Transcript(engine: "fake/1", createdAt: date("2026-11-10T03:00:00Z"), hotwords: [],
                                    items: [.sentence(.init(id: "s1", start: 0, end: 2, text: "你好"))])
        try store.saveTranscript(transcript, for: m.id)
        #expect(store.hasTranscript(m.id))
        #expect(try store.loadTranscriptSummary(m.id)
            == TranscriptSummary(createdAt: try #require(try store.loadTranscript(m.id)).createdAt, hasSpeakers: false))

        transcript.diarization = Diarization(engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1",
                                             speakersCreatedAt: date("2026-11-10T03:01:00Z"), speakers: [])
        try store.saveTranscript(transcript, for: m.id)
        #expect(try store.loadTranscriptSummary(m.id)?.hasSpeakers == true)
    }

    @Test func 声纹不是合法的float32base64时读取失败() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        let broken = """
        {
          "createdAt" : "2026-11-10T03:00:00Z", "engine" : "fake/1", "hotwords" : [], "items" : [], "version" : 1,
          "diarization" : {
            "engine" : "fake-diarizer/1", "voiceprintModel" : "fake-embedding/1",
            "speakersCreatedAt" : "2026-11-10T03:01:00Z",
            "speakers" : [ { "id" : "spk1", "speechDuration" : 3, "voiceprint" : "AAAA" } ]
          }
        }
        """
        // "AAAA" 解出 3 个字节，不是 4 的倍数
        try Data(broken.utf8).write(to: store.directory(m.id).appendingPathComponent("transcript.json"))
        #expect(throws: (any Error).self) { try store.loadTranscript(m.id) }
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

    /// v0.4 写出的 meeting.json（逐字）：没有标注的会议读入再保存，文件与 v0.4 逐字节相同
    @Test func 没有标注时写出的文件与v04相同() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let v04 = """
        {
          "diarization" : {
            "status" : "done"
          },
          "duration" : 3540,
          "endedAt" : "2026-11-10T03:00:00Z",
          "gaps" : [
            {
              "end" : "2026-11-10T02:11:00Z",
              "reason" : "lidClosed",
              "start" : "2026-11-10T02:10:00Z"
            }
          ],
          "id" : "2026-11-10_10-00-00",
          "minutes" : {
            "status" : "done"
          },
          "recording" : "recording.m4a",
          "segments" : [
            {
              "channels" : 1,
              "device" : "MacBook Pro 麦克风",
              "deviceUID" : "BuiltIn",
              "duration" : 3540,
              "file" : "0001.caf",
              "offset" : 0,
              "sampleRate" : 48000,
              "startedAt" : "2026-11-10T02:00:00Z"
            }
          ],
          "startedAt" : "2026-11-10T02:00:00Z",
          "status" : "done",
          "title" : "会议 11月10日 10:00",
          "transcription" : {
            "status" : "done"
          }
        }
        """
        let dir = store.directory("2026-11-10_10-00-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meeting.json")
        try Data(v04.utf8).write(to: url)

        let loaded = try #require(store.loadAll().first)
        #expect(loaded.annotationList.isEmpty)
        try store.save(loaded)
        #expect(try String(contentsOf: url, encoding: .utf8) == v04)
    }

    /// 标注时间来自 `Date()`，带小数秒；写盘丢小数秒。创建时就取整秒，存盘读回后会议和哈希都不变
    @Test func 标注按约定字段写入并能读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        m.addMark(at: date("2026-11-10T02:05:00Z").addingTimeInterval(0.75))
        m.addNote("预算 → 老王确认", at: date("2026-11-10T02:06:30Z").addingTimeInterval(0.25))
        try store.save(m)

        let loaded = try #require(MeetingStore(root: store.root).loadAll().first)
        #expect(loaded == m)
        #expect(loaded.annotationsHash == m.annotationsHash)

        let url = store.directory(m.id).appendingPathComponent("meeting.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let annotations = try #require(json["annotations"] as? [[String: Any]])
        #expect(annotations.count == 2)
        #expect(annotations[0] as NSDictionary == ["id": "a1", "at": "2026-11-10T02:05:00Z", "kind": "mark"])
        #expect(annotations[1] as NSDictionary
            == ["id": "a2", "at": "2026-11-10T02:06:30Z", "kind": "note", "text": "预算 → 老王确认"])
        #expect(json["lastAnnotationNumber"] as? Int == 2)
    }
}
