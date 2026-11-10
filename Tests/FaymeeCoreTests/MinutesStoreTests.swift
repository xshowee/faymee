import Foundation
import Testing
@testable import FaymeeCore

private func makeStore() -> MeetingStore {
    MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
}

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

/// 与 spec「纪要结构（草案）」对应的一份纪要，另加一条被修改过的决议、一条手动添加的未决问题
private let sample = Minutes(
    model: "mlx/qwen3-8b-4bit", template: "weekly", createdAt: date("2026-11-10T03:05:00Z"),
    source: MinutesSource(transcriptCreatedAt: date("2026-11-10T03:01:00Z"), textHash: "sha256:abc"),
    sections: [
        MinutesSection(kind: .overview, title: "概要", items: [
            MinutesItem(id: "o1", text: "讨论了 v2.3 的发布时间",
                        refs: [MinutesRef(id: "s120", start: 760.4), MinutesRef(id: "s131", start: 812.0)]),
        ]),
        MinutesSection(kind: .decisions, title: "决议", items: [
            MinutesItem(id: "d1", text: "v2.3 推迟到 11 月 24 日发布", refs: [MinutesRef(id: "s200", start: 902)],
                        original: MinutesItem.Original(text: "v2.3 推迟一周")),
        ]),
        MinutesSection(kind: .actions, title: "待办", items: [
            MinutesItem(id: "a1", text: "把报价单发给客户", owner: "张三", due: "下周三",
                        dueDate: CalendarDate(year: 2026, month: 11, day: 18)!,
                        refs: [MinutesRef(id: "s412", start: 1880.2)]),
            MinutesItem(id: "a2", text: "整理会议室预订规则", refs: [], deleted: true),
        ]),
        MinutesSection(kind: .questions, title: "未决问题", items: [
            MinutesItem(id: "m1", text: "海外版的预算", refs: [], origin: .manual),
        ]),
        MinutesSection(kind: .custom("commitments"), title: "我方承诺", items: []),
    ])

@Suite struct MinutesStoreTests {
    @Test func 纪要按约定格式写入并能读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))

        #expect(try store.loadMinutes(m.id) == nil)
        try store.saveMinutes(sample, for: m.id)
        #expect(try store.loadMinutes(m.id) == sample)
        #expect(try MeetingStore(root: store.root).loadMinutes(m.id) == sample)
    }

    /// 文件格式是 03 管线、06 界面、07 编辑、08 导出共用的契约，逐字段核对 spec 草案
    @Test func 文件字段与spec草案一致() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        try store.saveMinutes(sample, for: m.id)

        let url = store.directory(m.id).appendingPathComponent("minutes.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(json.keys) == ["version", "model", "template", "createdAt", "source", "sections"])
        #expect(json["version"] as? Int == 1)
        #expect(json["model"] as? String == "mlx/qwen3-8b-4bit")
        #expect(json["template"] as? String == "weekly")
        #expect(json["createdAt"] as? String == "2026-11-10T03:05:00Z")
        let source = try #require(json["source"] as? [String: Any])
        #expect(Set(source.keys) == ["transcriptCreatedAt", "textHash"])
        #expect(source["transcriptCreatedAt"] as? String == "2026-11-10T03:01:00Z")
        #expect(source["textHash"] as? String == "sha256:abc")

        let sections = try #require(json["sections"] as? [[String: Any]])
        #expect(sections.map { $0["kind"] as? String } == ["overview", "decisions", "actions", "questions", "custom"])
        #expect(sections.map { $0["title"] as? String } == ["概要", "决议", "待办", "未决问题", "我方承诺"])
        // key 只出现在 custom 节
        #expect(sections[0..<4].allSatisfy { Set($0.keys) == ["kind", "title", "items"] })
        #expect(Set(sections[4].keys) == ["kind", "key", "title", "items"])
        #expect(sections[4]["key"] as? String == "commitments")
        #expect((sections[4]["items"] as? [Any])?.isEmpty == true)

        let commonKeys: Set<String> = ["id", "text", "refs", "origin", "original", "deleted"]
        let actionKeys = commonKeys.union(["owner", "due", "dueDate"])

        let o1 = try #require((sections[0]["items"] as? [[String: Any]])?.first)
        #expect(Set(o1.keys) == commonKeys)
        #expect(o1["id"] as? String == "o1")
        #expect(o1["text"] as? String == "讨论了 v2.3 的发布时间")
        let refs = try #require(o1["refs"] as? [[String: Any]])
        #expect(refs.map { Set($0.keys) } == [["id", "start"], ["id", "start"]])
        #expect(refs.map { $0["id"] as? String } == ["s120", "s131"])
        #expect(refs.map { $0["start"] as? Double } == [760.4, 812.0])
        #expect(o1["origin"] as? String == "model")
        #expect(o1["original"] is NSNull)
        #expect(o1["deleted"] as? Bool == false)

        // 非待办条目的 original 只有 text
        let d1 = try #require((sections[1]["items"] as? [[String: Any]])?.first)
        let d1Original = try #require(d1["original"] as? [String: Any])
        #expect(Set(d1Original.keys) == ["text"])
        #expect(d1Original["text"] as? String == "v2.3 推迟一周")

        let actions = try #require(sections[2]["items"] as? [[String: Any]])
        #expect(Set(actions[0].keys) == actionKeys)
        #expect(actions[0]["owner"] as? String == "张三")
        #expect(actions[0]["due"] as? String == "下周三")
        #expect(actions[0]["dueDate"] as? String == "2026-11-18")
        // 负责人、截止时间为空的待办照样写出这三个字段，值为 null
        #expect(Set(actions[1].keys) == actionKeys)
        #expect(actions[1]["owner"] is NSNull)
        #expect(actions[1]["due"] is NSNull)
        #expect(actions[1]["dueDate"] is NSNull)
        #expect(actions[1]["deleted"] as? Bool == true)

        let m1 = try #require((sections[3]["items"] as? [[String: Any]])?.first)
        #expect(m1["origin"] as? String == "manual")
        #expect((m1["refs"] as? [Any])?.isEmpty == true)
    }

    /// 待办被修改过时，original 存模型给的 text、owner、due、dueDate 四项
    @Test func 修改过的待办原文能读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        var minutes = sample
        minutes.sections[2].items[0].original = MinutesItem.Original(
            text: "发报价单", owner: nil, due: "周三", dueDate: CalendarDate(year: 2026, month: 11, day: 11)!)
        try store.saveMinutes(minutes, for: m.id)

        #expect(try store.loadMinutes(m.id) == minutes)
        let url = store.directory(m.id).appendingPathComponent("minutes.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sections = try #require(json["sections"] as? [[String: Any]])
        let a1 = try #require((sections[2]["items"] as? [[String: Any]])?.first)
        let original = try #require(a1["original"] as? [String: Any])
        #expect(Set(original.keys) == ["text", "owner", "due", "dueDate"])
        #expect(original["text"] as? String == "发报价单")
        #expect(original["owner"] is NSNull)
        #expect(original["due"] as? String == "周三")
        #expect(original["dueDate"] as? String == "2026-11-11")
    }

    /// v0.4 新增的字段都可选：没有时不写（上面逐字段核对的就是 v0.3 的形状），有时按约定写出并能读回
    @Test func 说话人相关字段按约定写出并能读回() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        var minutes = sample
        minutes.source.speakersCreatedAt = date("2026-11-10T03:02:00Z")
        minutes.sections[2].items[0].ownerSpeaker = "spk2"
        minutes.sections[2].items[0].original = MinutesItem.Original(text: "发报价单", owner: "说话人 3",
                                                                       ownerSpeaker: "spk3")
        minutes.nameSuggestions = [
            NameSuggestion(speaker: "spk2", name: "王总", refs: [MinutesRef(id: "s30", start: 300.5)]),
            NameSuggestion(speaker: "spk3", name: "李总", refs: [], ignored: true),
        ]
        try store.saveMinutes(minutes, for: m.id)

        #expect(try store.loadMinutes(m.id) == minutes)
        let url = store.directory(m.id).appendingPathComponent("minutes.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let source = try #require(json["source"] as? [String: Any])
        #expect(source["speakersCreatedAt"] as? String == "2026-11-10T03:02:00Z")
        let suggestions = try #require(json["nameSuggestions"] as? [[String: Any]])
        #expect(suggestions.map { Set($0.keys) } == [["speaker", "name", "refs", "ignored"],
                                                      ["speaker", "name", "refs", "ignored"]])
        #expect(suggestions.map { $0["speaker"] as? String } == ["spk2", "spk3"])
        #expect(suggestions.map { $0["name"] as? String } == ["王总", "李总"])
        #expect(suggestions.map { $0["ignored"] as? Bool } == [false, true])
        #expect((suggestions[0]["refs"] as? [[String: Any]])?.first?["id"] as? String == "s30")

        let sections = try #require(json["sections"] as? [[String: Any]])
        let actions = try #require(sections[2]["items"] as? [[String: Any]])
        #expect(actions[0]["ownerSpeaker"] as? String == "spk2")
        #expect((actions[0]["original"] as? [String: Any])?["ownerSpeaker"] as? String == "spk3")
        // 没有关联的待办不写这个字段
        #expect(!actions[1].keys.contains("ownerSpeaker"))
    }

    @Test func 纪要文件损坏时抛错() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        try Data("{".utf8).write(to: store.directory(m.id).appendingPathComponent("minutes.json"))

        #expect(throws: (any Error).self) { try store.loadMinutes(m.id) }
    }

    @Test func 截止日期不是合法日期时文件视为损坏() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let m = try store.create(startedAt: date("2026-11-10T02:00:00Z"))
        try store.saveMinutes(sample, for: m.id)
        let url = store.directory(m.id).appendingPathComponent("minutes.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "2026-11-18", with: "2026-02-30").utf8).write(to: url)

        #expect(throws: (any Error).self) { try store.loadMinutes(m.id) }
    }

    /// 生成过程中删除会议：写纪要失败，不会把目录重建出来
    @Test func 会议目录不存在时写入失败() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        #expect(throws: (any Error).self) { try store.saveMinutes(sample, for: "gone") }
        #expect(!FileManager.default.fileExists(atPath: store.directory("gone").path))
    }
}
