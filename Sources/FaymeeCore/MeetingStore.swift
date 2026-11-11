import Foundation

/// 会议存储：每场会议一个目录
///
///     ~/Library/Application Support/Faymee/Meetings/<id>/
///         meeting.json        元数据（原子写入）
///         segments/0001.caf   录音分片，整理完成后删除
///         recording.m4a       合并后的录音
///         transcript.json     转写稿（原子写入），只由转写和编辑写入
///         minutes.json        纪要（原子写入），只由生成和编辑写入
///
/// 文件系统是唯一的数据来源；分片以磁盘上的文件为准，不依赖 meeting.json 是否记全。
public final class MeetingStore {
    public let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faymee/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func segmentsDirectory(_ id: String) -> URL { directory(id).appendingPathComponent("segments", isDirectory: true) }
    private func manifest(_ id: String) -> URL { directory(id).appendingPathComponent("meeting.json") }
    private func transcriptURL(_ id: String) -> URL { directory(id).appendingPathComponent("transcript.json") }
    private func minutesURL(_ id: String) -> URL { directory(id).appendingPathComponent("minutes.json") }

    public func recordingURL(_ m: Meeting) -> URL? {
        m.recording.map { directory(m.id).appendingPathComponent($0) }
    }

    public func create(startedAt: Date) throws -> Meeting {
        let idFormat = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits)",
            timeZone: .current, calendar: .current)
        var id = startedAt.formatted(idFormat)
        var n = 2
        while FileManager.default.fileExists(atPath: directory(id).path) {
            id = "\(startedAt.formatted(idFormat))-\(n)"
            n += 1
        }
        let title = "会议 " + startedAt.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
        let m = Meeting(id: id, title: title, startedAt: startedAt, status: .recording)
        try FileManager.default.createDirectory(at: segmentsDirectory(id), withIntermediateDirectories: true)
        try save(m)
        return m
    }

    public func save(_ m: Meeting) throws {
        try encoder.encode(m).write(to: manifest(m.id), options: .atomic)
    }

    public func loadAll() -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// 还没有转写稿时返回 nil；文件存在但读不了时抛错，免得界面把“坏了”当成“没有”
    public func loadTranscript(_ id: String) throws -> Transcript? {
        let url = transcriptURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(Transcript.self, from: Data(contentsOf: url))
    }

    /// 有没有转写稿文件（不读内容，不管能不能读）
    public func hasTranscript(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(id).path)
    }

    /// 只读转写稿的生成时间和有没有说话人，不解出句子和说话人。管线在主线程上判断状态用，
    /// 长会议的转写稿完整解码会卡界面。`createdAt` 与 `loadTranscript` 读出的相等。
    /// 还没有转写稿时返回 nil；文件存在但读不了时抛错
    public func loadTranscriptSummary(_ id: String) throws -> TranscriptSummary? {
        let url = transcriptURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(TranscriptSummary.self, from: Data(contentsOf: url))
    }

    /// 原子写入：中途崩溃不会留下半份转写稿。会议目录已不存在（被删除）时失败，不会重建目录
    public func saveTranscript(_ t: Transcript, for id: String) throws {
        try encoder.encode(t).write(to: transcriptURL(id), options: .atomic)
    }

    /// 还没有纪要时返回 nil；文件存在但读不了时抛错，免得界面把“坏了”当成“没有”
    public func loadMinutes(_ id: String) throws -> Minutes? {
        let url = minutesURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(Minutes.self, from: Data(contentsOf: url))
    }

    /// 原子写入：中途崩溃不会留下半份纪要。会议目录已不存在（被删除）时失败，不会重建目录
    public func saveMinutes(_ m: Minutes, for id: String) throws {
        try encoder.encode(m).write(to: minutesURL(id), options: .atomic)
    }

    /// 磁盘上的录音分片，按文件名（即录制顺序）排序
    public func segmentFiles(_ id: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: segmentsDirectory(id), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "caf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 移到废纸篓而不是直接删除，误删还能找回
    public func trash(_ id: String) throws {
        try FileManager.default.trashItem(at: directory(id), resultingItemURL: nil)
    }
}

/// 转写稿的摘要，见 `MeetingStore.loadTranscriptSummary(_:)`
public struct TranscriptSummary: Decodable, Hashable, Sendable {
    public var createdAt: Date
    /// 区分过说话人（`Transcript.diarization` 不为 nil）
    public var hasSpeakers: Bool

    public init(createdAt: Date, hasSpeakers: Bool) {
        self.createdAt = createdAt
        self.hasSpeakers = hasSpeakers
    }

    private enum CodingKeys: String, CodingKey { case createdAt, diarization }

    /// 只看字段在不在，不解它的内容
    private struct Present: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        hasSpeakers = try c.decodeIfPresent(Present.self, forKey: .diarization) != nil
    }
}
