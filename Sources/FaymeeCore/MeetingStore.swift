import Foundation

/// 会议存储：每场会议一个目录
///
///     ~/Library/Application Support/Faymee/Meetings/<id>/
///         meeting.json        元数据（原子写入）
///         segments/0001.caf   录音分片，整理完成后删除
///         recording.m4a       合并后的录音
///         transcript.json     转写稿（原子写入），只由转写和编辑写入
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

    /// 原子写入：中途崩溃不会留下半份转写稿。会议目录已不存在（被删除）时失败，不会重建目录
    public func saveTranscript(_ t: Transcript, for id: String) throws {
        try encoder.encode(t).write(to: transcriptURL(id), options: .atomic)
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
