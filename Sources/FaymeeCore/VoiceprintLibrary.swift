import Foundation

/// 声纹库：用户主动登记过的人和他们的声纹样本，全局一份，只存在本机。
/// 用来在以后的会议里自动认出这些人。改名、删除不回写过去的会议
public struct VoiceprintLibrary: Codable, Hashable, Sendable {
    public var people: [VoiceprintPerson]

    public init(people: [VoiceprintPerson] = []) {
        self.people = people
    }
}

public struct VoiceprintPerson: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// 样本声纹所用的模型。与当前引擎不同时不参与识别，需要重新登记
    public var voiceprintModel: String
    /// 按加入先后，最早的在前
    public var samples: [VoiceprintSample]

    public init(id: String, name: String, voiceprintModel: String, samples: [VoiceprintSample]) {
        self.id = id
        self.name = name
        self.voiceprintModel = voiceprintModel
        self.samples = samples
    }
}

/// 某场会议里这个人的一份声纹
public struct VoiceprintSample: Codable, Hashable, Sendable {
    public var voiceprint: Voiceprint
    /// 来源会议 id
    public var meetingID: String
    /// 该说话人在来源会议里的有效发言时长（秒）
    public var speechDuration: TimeInterval
    public var addedAt: Date

    public init(voiceprint: Voiceprint, meetingID: String, speechDuration: TimeInterval, addedAt: Date) {
        self.voiceprint = voiceprint
        self.meetingID = meetingID
        self.speechDuration = speechDuration
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case voiceprint, meetingID = "meetingId", speechDuration, addedAt
    }
}

extension VoiceprintLibrary {
    /// 每人最多保留的样本数，超出时丢最早的
    public static let maxSamplesPerPerson = 10
    /// 有效发言少于这个时长（秒）的说话人不能登记，声纹不可靠
    public static let minimumEnrollmentDuration: TimeInterval = 10

    /// 记住这个声音：把某场会议里一个已命名说话人的声纹加进声纹库，返回人员 id。只在用户主动操作时调用。
    /// - 按名字（去首尾空白）找人：同名已有人员时加样本，否则新建
    /// - 同名人员的声纹模型与这场不同（换过引擎）时，旧样本不可比，丢掉旧样本、换成这场的模型，等于重新登记
    /// - 同一场会议已经给这个人登记过时，替换这场的样本（合并说话人后再登记一次，不重复计入）
    /// - 超过 `maxSamplesPerPerson` 时丢最早加入的
    @discardableResult
    public mutating func enroll(speaker id: String, from transcript: Transcript, meetingID: String,
                                now: Date = Date(), newID: () -> String = { UUID().uuidString }) throws -> String {
        let (speaker, name, model) = try Self.enrollable(speaker: id, in: transcript)
        let sample = VoiceprintSample(voiceprint: speaker.voiceprint, meetingID: meetingID,
                                      speechDuration: speaker.speechDuration, addedAt: now)
        guard let i = people.firstIndex(where: { $0.name == name }) else {
            let person = VoiceprintPerson(id: newID(), name: name, voiceprintModel: model, samples: [sample])
            people.append(person)
            return person.id
        }
        if people[i].voiceprintModel != model {
            people[i].voiceprintModel = model
            people[i].samples = []
        }
        people[i].samples.removeAll { $0.meetingID == meetingID }
        people[i].samples.append(sample)
        people[i].samples = Array(people[i].samples.suffix(Self.maxSamplesPerPerson))
        return people[i].id
    }
}

extension VoiceprintLibrary {
    /// 登记前的校验，不看声纹库：说话人存在、已命名、有声纹、有效发言够长，不满足时抛出原因。
    /// 通过时返回说话人、去首尾空白的名字和这场的声纹模型。`enroll` 和菜单项共用，判断一致
    static func enrollable(speaker id: String, in transcript: Transcript) throws
        -> (speaker: Speaker, name: String, voiceprintModel: String) {
        guard let diarization = transcript.diarization, let speaker = transcript.speaker(id) else {
            throw VoiceprintEnrollmentError.speakerNotFound
        }
        guard let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw VoiceprintEnrollmentError.unnamed
        }
        guard !speaker.voiceprint.vector.isEmpty else { throw VoiceprintEnrollmentError.noVoiceprint(name: name) }
        guard speaker.speechDuration >= minimumEnrollmentDuration else {
            throw VoiceprintEnrollmentError.tooShort(name: name, speechDuration: speaker.speechDuration)
        }
        return (speaker, name, diarization.voiceprintModel)
    }
}

/// 一个说话人被认作声纹库里的某人
public struct VoiceprintMatch: Hashable, Sendable {
    public var speakerID: String
    public var personID: String
    /// 声纹库里此人的名字，写到说话人上
    public var name: String
    /// 与此人各样本相似度的最大值
    public var similarity: Float

    public init(speakerID: String, personID: String, name: String, similarity: Float) {
        self.speakerID = speakerID
        self.personID = personID
        self.name = name
        self.similarity = similarity
    }
}

extension VoiceprintLibrary {
    /// 默认识别阈值（余弦相似度）。保守取值、宁可认不出也不认错，还没有用真实引擎校准：
    /// 引擎侧（05）给出推荐值后由调用方传 `threshold`，对比 ticket（12）再校准
    public static let defaultMatchThreshold: Float = 0.75

    /// 认出一场会议里的说话人。只读，不改声纹库、不加样本；把名字写到说话人上是调用方的事。
    /// - 只和声纹模型等于 `voiceprintModel` 的人比较；每人取与各样本相似度的最大值，超过阈值才算
    /// - 一个人只认给一个说话人、一个说话人只认一个人：所有超过阈值的配对按相似度从高到低贪心分配，
    ///   相同时按说话人列表顺序（先开口的优先）、再按声纹库顺序
    /// - 手动命名（`user`）的说话人不参与，也占住它对应的人：声纹库关联（`personID`）是此人，
    ///   或名字与此人相同时，此人不再认给别的说话人，免得一场里出现两个同名的人
    /// - 声纹认出（`voiceprint`）的、没命名的说话人都重新参与
    ///
    /// 返回按说话人列表顺序
    public func match(_ speakers: [Speaker], voiceprintModel: String,
                      threshold: Float = defaultMatchThreshold) -> [VoiceprintMatch] {
        let manual = speakers.filter { $0.nameSource == .user }
        let taken = Set(manual.compactMap(\.personID))
        let takenNames = Set(manual.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) })
        let candidates = people.filter {
            $0.voiceprintModel == voiceprintModel && !taken.contains($0.id) && !takenNames.contains($0.name)
        }

        struct Pair { var speaker: Int; var person: Int; var similarity: Float }
        var pairs: [Pair] = []
        for (si, s) in speakers.enumerated() where s.nameSource != .user {
            for (pi, p) in candidates.enumerated() {
                let similarity = p.samples.map { $0.voiceprint.similarity(to: s.voiceprint) }.max() ?? 0
                if similarity > threshold { pairs.append(Pair(speaker: si, person: pi, similarity: similarity)) }
            }
        }
        pairs.sort {
            ($0.similarity, -$0.speaker, -$0.person) > ($1.similarity, -$1.speaker, -$1.person)
        }

        var assigned: [Int: VoiceprintMatch] = [:]
        var usedPeople = Set<Int>()
        for pair in pairs where assigned[pair.speaker] == nil && !usedPeople.contains(pair.person) {
            let p = candidates[pair.person]
            assigned[pair.speaker] = VoiceprintMatch(speakerID: speakers[pair.speaker].id, personID: p.id,
                                                     name: p.name, similarity: pair.similarity)
            usedPeople.insert(pair.person)
        }
        return assigned.keys.sorted().compactMap { assigned[$0] }
    }
}

/// 声纹管理窗口的操作。都不回写过去的会议：已经显示的名字不变
extension VoiceprintLibrary {
    /// 名字去首尾空白。不能为空，不能与另一个人重名（登记按名字找人）
    public mutating func rename(_ id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw VoiceprintLibraryError.personNotFound }
        guard !name.isEmpty else { throw VoiceprintLibraryError.emptyName }
        guard !people.contains(where: { $0.id != id && $0.name == name }) else {
            throw VoiceprintLibraryError.duplicateName(name)
        }
        people[i].name = name
    }

    /// 删除某人和他的全部样本。之后的会议不再认出此人
    public mutating func remove(_ id: String) {
        people.removeAll { $0.id == id }
    }

    /// 声纹模型与当前引擎不同的人：不参与识别，管理窗口显示“需要重新登记”
    public func peopleNeedingReenrollment(voiceprintModel: String) -> [VoiceprintPerson] {
        people.filter { $0.needsReenrollment(voiceprintModel: voiceprintModel) }
    }
}

extension VoiceprintPerson {
    public func needsReenrollment(voiceprintModel: String) -> Bool {
        self.voiceprintModel != voiceprintModel
    }
}

public enum VoiceprintLibraryError: LocalizedError, Equatable {
    case personNotFound
    case emptyName
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .personNotFound: "声纹库里没有这个人"
        case .emptyName: "名字不能为空"
        case let .duplicateName(name): "声纹库里已经有“\(name)”了"
        }
    }
}

public enum VoiceprintEnrollmentError: LocalizedError, Equatable {
    /// 说话人不在这场的说话人列表里（或这场没区分过说话人）
    case speakerNotFound
    /// 还是“说话人 N”，先改名再登记
    case unnamed
    /// 没有声纹向量（单句改给新说话人建出来的人、引擎没给声纹）
    case noVoiceprint(name: String)
    /// 有效发言不足 `minimumEnrollmentDuration`
    case tooShort(name: String, speechDuration: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .speakerNotFound: "找不到这个说话人"
        case .unnamed: "先给这个说话人起名字，再记住声音"
        case let .noVoiceprint(name): "\(name)在这场会议里没有可用的声音"
        case let .tooShort(name, duration):
            "\(name)在这场会议里的有效发言只有 \(Int(duration)) 秒，"
                + "至少需要 \(Int(VoiceprintLibrary.minimumEnrollmentDuration)) 秒才能记住声音"
        }
    }
}

/// 声纹库存成 JSON，与热词表同级：
///
///     ~/Library/Application Support/Faymee/voiceprints.json
///
/// 整份原子写入。声纹是生物特征，只在本机
public struct VoiceprintStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faymee/voiceprints.json")
    }

    /// 还没有声纹库文件时返回空库；文件坏了抛错
    public func load() throws -> VoiceprintLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceprintLibrary() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(VoiceprintLibrary.self, from: Data(contentsOf: url))
    }

    public func save(_ library: VoiceprintLibrary) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(library).write(to: url, options: .atomic)
    }

    /// 读出、修改、写回。读不出来（文件坏了）时抛错、不写，免得一次修改把整个库覆盖成空的；
    /// body 抛错时也不写
    @discardableResult
    public func update<T>(_ body: (inout VoiceprintLibrary) throws -> T) throws -> T {
        var library = try load()
        let result = try body(&library)
        try save(library)
        return result
    }

    /// 全部删除：直接删掉文件，不先读。文件坏了也能清除
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
