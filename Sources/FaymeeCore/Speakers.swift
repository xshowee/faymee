import Foundation

/// 一份转写稿的说话人信息。整体可选：nil 表示从未区分说话人（含 v0.3 及更早的转写稿）。
/// 句子归给哪个说话人记在句子的 `speaker` 上
public struct Diarization: Codable, Hashable, Sendable {
    /// 区分说话人用的引擎，如 "sherpa-onnx/pyannote"
    public var engine: String
    /// 算声纹向量的模型。声纹只在同一模型之间可比
    public var voiceprintModel: String
    /// 区分完成的时间。纪要记下它，之后与当前转写稿比对：不同说明重新区分过，说话人编号已重排。
    /// 写盘时丢掉小数秒，比对时两边都要用从磁盘读回的值
    public var speakersCreatedAt: Date
    /// 按 id 编号顺序（第一次开口的先后）
    public var speakers: [Speaker]

    public init(engine: String, voiceprintModel: String, speakersCreatedAt: Date, speakers: [Speaker]) {
        self.engine = engine
        self.voiceprintModel = voiceprintModel
        self.speakersCreatedAt = speakersCreatedAt
        self.speakers = speakers
    }
}

public enum SpeakerNameSource: String, Codable, Sendable {
    /// 手动命名（含改名、合并、采纳姓名建议）
    case user
    /// 声纹库自动认出
    case voiceprint
}

public struct Speaker: Codable, Hashable, Sendable {
    /// `spk1`、`spk2`……，按第一次开口先后编号，在一份转写稿内稳定
    public var id: String
    /// nil 时显示“说话人 N”
    public var name: String?
    public var nameSource: SpeakerNameSource?
    /// 由声纹认出时对应的声纹库人员 id
    public var personID: String?
    /// 该说话人全部片段的平均声纹
    public var voiceprint: Voiceprint
    /// 有效发言时长（秒）：区分结果里这个人的说话片段总长，不含合盖空白
    public var speechDuration: TimeInterval

    public init(id: String, name: String? = nil, nameSource: SpeakerNameSource? = nil, personID: String? = nil,
                voiceprint: Voiceprint, speechDuration: TimeInterval) {
        self.id = id
        self.name = name
        self.nameSource = nameSource
        self.personID = personID
        self.voiceprint = voiceprint
        self.speechDuration = speechDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nameSource, personID = "personId", voiceprint, speechDuration
    }
}

/// 声纹向量。写盘为 float32 小端字节的 base64 字符串
public struct Voiceprint: Codable, Hashable, Sendable {
    public var vector: [Float]

    public init(_ vector: [Float]) {
        self.vector = vector
    }

    /// 余弦相似度，-1...1，与引擎无关。维数不同（换了声纹模型）、空向量、零向量都不可比，返回 0（当作不像）
    public func similarity(to other: Voiceprint) -> Float {
        let a = vector, b = other.vector
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard let data = Data(base64Encoded: try c.decode(String.self)), data.count % 4 == 0 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "声纹不是 float32 的 base64")
        }
        let bytes = [UInt8](data)
        vector = stride(from: 0, to: bytes.count, by: 4).map { i in
            Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var data = Data(capacity: vector.count * 4)
        for f in vector {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        var c = encoder.singleValueContainer()
        try c.encode(data.base64EncodedString())
    }
}

/// 单句改过说话人时记下的区分结果原值，作用同句子的 `original`：统计修改数、恢复。
/// 原值本身可能是“未知”（`speaker` 为 nil），所以包一层，与“没改过”（整个为 nil）区分开
public struct OriginalSpeaker: Codable, Hashable, Sendable {
    public var speaker: String?

    public init(speaker: String?) {
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey { case speaker }

    public init(from decoder: Decoder) throws {
        speaker = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .speaker)
    }

    /// 原值为未知时写 `null`，不省略
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(speaker, forKey: .speaker)
    }
}

extension Transcript {
    /// 说话人列表；没区分过时为空
    public var speakers: [Speaker] { diarization?.speakers ?? [] }

    public var speakersCreatedAt: Date? { diarization?.speakersCreatedAt }
}

extension Speaker {
    /// 没有名字（或名字是空白）时显示“说话人 N”，N 取自 id 的编号（spk3 → 3），不是列表位置，合并后不变
    public var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "说话人 \(id.hasPrefix("spk") ? String(id.dropFirst(3)) : id)"
    }

    /// 句子没有说话人（与任何说话片段都不重合）时显示的名字
    public static let unknownName = "未知"
}

extension Transcript {
    public func speaker(_ id: String) -> Speaker? {
        speakers.first { $0.id == id }
    }

    /// 句子的说话人显示名；没有说话人时为“未知”。只在 `showsSpeakers` 时显示
    public func speakerName(for sentence: TranscriptSentence) -> String {
        sentence.speaker.flatMap(speaker)?.displayName ?? Speaker.unknownName
    }

    /// 句子实际用到两个及以上说话人时，界面和导出才显示说话人。
    /// 只有一个人（加上几句未知也算）或没区分过时不显示；列表里有但一句都没有的说话人不算
    public var showsSpeakers: Bool {
        var seen: String?
        for s in sentences {
            guard let id = s.speaker else { continue }
            if let seen, seen != id { return true }
            seen = id
        }
        return false
    }
}
