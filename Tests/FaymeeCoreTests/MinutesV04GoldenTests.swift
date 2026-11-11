import Foundation
import Testing
@testable import FaymeeCore

/// 没有会中标注时，纪要生成的提示词、文法、写出的 minutes.json 与 v0.4 逐字相同（spec「测试决定」）。
/// 期望值在 Resources/minutes-v0.4/ 下，是 v0.5 改动之前的代码跑出来的原样输出，不要用新代码重新生成

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

private func speaker(_ id: String, _ name: String? = nil) -> Speaker {
    Speaker(id: id, name: name, nameSource: name == nil ? nil : .user, voiceprint: Voiceprint([1]), speechDuration: 30)
}

/// 一场带说话人、中间合盖的长会议：要分段提取再合并
private let longWithSpeakers: Transcript = {
    let speakers = ["spk1", "spk2", "spk3", nil]
    var items: [TranscriptItem] = []
    var t: TimeInterval = 0
    for i in 1...60 {
        let text = i == 3 ? "王总你怎么看这个方案，下周三之前把报价单发给客户" : "这是第\(i)句话，大家讨论了项目的进度和下一步的安排"
        items.append(.sentence(TranscriptSentence(id: "s\(i)", start: t, end: t + 8, text: text,
                                                  speaker: speakers[i % 4])))
        t += 10
        if i == 30 {
            items.append(.gap(TranscriptGap(start: t, end: t + 120, reason: .lidClosed)))
            t += 120
        }
    }
    return Transcript(engine: "apple/speechanalyzer", createdAt: date("2026-11-10T03:01:00Z"), hotwords: [],
                      items: items,
                      diarization: Diarization(engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1",
                                               speakersCreatedAt: date("2026-11-10T03:02:00Z"),
                                               speakers: [speaker("spk1"), speaker("spk2"), speaker("spk3", "张三")]))
}()

/// 五句、一段合盖空白、一句改过，没有说话人
private let short = Transcript(
    engine: "apple/speechanalyzer", createdAt: date("2026-11-10T03:01:00Z"), hotwords: [],
    items: [
        .sentence(TranscriptSentence(id: "s1", start: 3.2, end: 6, text: "我们今天讨论 v2.3 的发布时间")),
        .sentence(TranscriptSentence(id: "s2", start: 760.4, end: 765, text: "支付接口还没准备好")),
        .gap(TranscriptGap(start: 800, end: 980, reason: .lidClosed)),
        .sentence(TranscriptSentence(id: "s3", start: 1880.2, end: 1885, text: "张三你下周三之前把报价单发给客户",
                                     original: "张三你下周三之前把报价但发给客户")),
        .sentence(TranscriptSentence(id: "s4", start: 1890, end: 1893, text: "那就推迟一周发布")),
        .sentence(TranscriptSentence(id: "s5", start: 2645.5, end: 2650, text: "海外版的预算还没定")),
    ])

/// 提取时每段一条概要、一条待办、一条周会进展，s3 所在的段给王总的姓名推断；合并时收拢出处
private func respond(_ system: String, _ prompt: String) -> String {
    let lines = transcriptLines(in: prompt)
    if let first = lines.first(where: { $0.hasPrefix("[s") }) {
        let id = first.dropFirst().prefix { $0 != " " }
        let guess = lines.contains { $0.hasPrefix("[s3 ") }
            ? #", "speakers": [{"speaker": "说话人 1", "name": "王总", "refs": ["s3"]}]"# : ""
        return #"""
        {"overview": [{"text": "\#(id) 开始的一段", "refs": ["\#(id)"]}], "decisions": [],
         "actions": [{"text": "把报价单发给客户", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["\#(id)"]}],
         "questions": [], "progress": [{"text": "\#(id) 的进展", "refs": ["\#(id)"]}]\#(guess)}
        """#
    }
    let ids = prompt.matches(of: try! Regex(#""s\d+""#)).map { String(prompt[$0.range]) }
    return #"""
    {"overview": [{"text": "全场概要", "refs": [\#(ids.prefix(3).joined(separator: ", "))]}],
     "decisions": [{"text": "按计划推进", "refs": [\#(ids.prefix(1).joined())]}],
     "actions": [{"text": "把报价单发给客户", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s3"]}],
     "questions": [], "progress": []}
    """#
}

/// 每次调用的系统提示、提示词、maxTokens、文法，再加写出的 minutes.json
private func record(_ transcript: Transcript, template: MinutesTemplate, contextTokens: Int) async throws -> String {
    let generator = ScriptedGenerator(contextTokens: contextTokens)
    generator.respond = respond
    let minutes = try await generateMinutes(
        transcript: transcript, title: "产品周会", startedAt: date("2026-11-10T02:00:00Z"), template: template,
        generator: generator, model: "fake/scripted", createdAt: date("2026-11-10T03:05:00Z"), timeZone: shanghai)

    let store = MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: store.root) }
    try FileManager.default.createDirectory(at: store.directory("m1"), withIntermediateDirectories: true)
    try store.saveMinutes(minutes, for: "m1")
    let json = try String(contentsOf: store.directory("m1").appendingPathComponent("minutes.json"), encoding: .utf8)

    var out = ""
    for (n, call) in generator.calls.enumerated() {
        out += "=== 第 \(n + 1) 次调用 maxTokens=\(call.maxTokens) ===\n"
        out += "--- system ---\n\(call.system)\n--- prompt ---\n\(call.prompt)\n"
        out += "--- grammar ---\n\(generator.grammars[n] ?? "nil")\n"
    }
    return out + "=== minutes.json ===\n" + json + "\n"
}

private func golden(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt",
                                             subdirectory: "Resources/minutes-v0.4"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct MinutesV04GoldenTests {
    @Test func 带说话人的长会议分段提取再合并_与v04逐字相同() async throws {
        let actual = try await record(longWithSpeakers, template: .weekly, contextTokens: 4000)
        #expect(actual == (try golden("long-with-speakers")))
    }

    @Test func 没有说话人的短会议一次提取_与v04逐字相同() async throws {
        let actual = try await record(short, template: .general, contextTokens: 100_000)
        #expect(actual == (try golden("short")))
    }

    /// 旧文件照常读取，原样写回逐字节不变
    @Test(arguments: ["long-with-speakers", "short"])
    func v04的minutes_json读回再写出逐字节不变(name: String) throws {
        let json = try #require(try golden(name).components(separatedBy: "=== minutes.json ===\n").last)
            .dropLast()
        let store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let url = store.directory("m1").appendingPathComponent("minutes.json")
        try FileManager.default.createDirectory(at: store.directory("m1"), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)

        let minutes = try #require(try store.loadMinutes("m1"))
        try store.saveMinutes(minutes, for: "m1")

        #expect(try String(contentsOf: url, encoding: .utf8) == String(json))
    }
}

