import Foundation

/// 模型的用途。设置里每个用途一个选择框
public enum ModelRole: String, CaseIterable, Sendable, Hashable {
    /// 会后转写
    case transcription
    /// 实时字幕
    case liveCaptions
    /// 实时字幕定稿（第二遍，可以不用）
    case liveFinalize
    /// 纪要
    case minutes
    /// 声纹（区分说话人、声纹库）
    case voiceprint

    public var displayName: String {
        switch self {
        case .transcription: "会后转写"
        case .liveCaptions: "实时字幕"
        case .liveFinalize: "实时字幕定稿"
        case .minutes: "纪要"
        case .voiceprint: "声纹"
        }
    }

    /// 可以选“不用”（选中的 id 为 nil）
    public var allowsNone: Bool { self == .liveFinalize }
}

/// 模型家族：决定用哪个适配器跑它。同一家族加新模型只加目录项
public enum ModelFamily: String, Sendable, Hashable {
    case speechAnalyzer
    case sherpaParaformer
    case sherpaFunASRNano
    case sherpaQwen3ASR
    case sherpaOnlineTransducer
    case llamaGGUF
    case sherpaSpeakerEmbedding
    /// 辅助模型：标点（CT-Transformer）
    case sherpaPunctuation
    /// 辅助模型：静音切段（Silero VAD）
    case sileroVAD
}

/// 模型文件从哪来
public enum ModelSource: Sendable, Equatable {
    /// 系统自带（SpeechAnalyzer），不用下载
    case system
    /// 已打进 App：`Contents/Resources/<directory>/<fileName>`，由 build 脚本拷入（如 scripts/fetch-*.sh）
    case bundled(directory: String, fileName: String)
    /// 用时下载到 `Models/<directoryName>/`
    case download(LocalModel)
}

/// 逐字时间
public enum WordTimings: Sendable, Hashable {
    /// 模型给出真实的逐字时间
    case real
    /// 没有真实逐字时间，句子时间在段内按字数估算
    case estimated
}

/// 转写类模型的能力
public struct ModelCapabilities: Sendable, Hashable {
    /// 输出带标点（含靠辅助的标点模型）
    public var punctuation: Bool
    public var wordTimings: WordTimings
    /// 热词表生效
    public var hotwords: Bool

    public init(punctuation: Bool, wordTimings: WordTimings, hotwords: Bool) {
        self.punctuation = punctuation
        self.wordTimings = wordTimings
        self.hotwords = hotwords
    }
}

/// 家族参数：只填这个家族用得到的。适配器读它，不在代码里按模型写死
public struct ModelParameters: Sendable, Hashable {
    /// 上下文窗口（token）：Fun-ASR-Nano / Qwen3-ASR 的 LLM 上下文，纪要模型的 n_ctx
    public var contextTokens: Int?
    /// 热词最多占多少 token（与音频、输出共用上下文）
    public var hotwordTokenBudget: Int?
    /// 声纹库匹配阈值（余弦相似度）。阈值和模型相关，换模型必须带上自己的
    public var matchThreshold: Float?

    public init(contextTokens: Int? = nil, hotwordTokenBudget: Int? = nil, matchThreshold: Float? = nil) {
        self.contextTokens = contextTokens
        self.hotwordTokenBudget = hotwordTokenBudget
        self.matchThreshold = matchThreshold
    }
}

/// 目录里的一个模型
public struct CatalogModel: Sendable, Equatable, Identifiable {
    /// 稳定标识，写进转写稿 / 纪要 / 说话人结果。下载类模型与 `LocalModel.id` 相同
    public let id: String
    /// 能用在哪些用途。同一个模型可以有多个用途（如 Paraformer 既做会后转写也做定稿，共用文件）；
    /// 辅助模型为空，不出现在任何选择框里
    public let roles: Set<ModelRole>
    public let family: ModelFamily
    public let source: ModelSource
    /// 选择框里显示的名字
    public let name: String
    /// 内存峰值，如“约 2.1 GB”
    public let memory: String?
    /// 速度，如“20 分钟会议约 2 分钟”
    public let speed: String?
    /// 能力（转写类模型才有）
    public let capabilities: ModelCapabilities?
    /// 一句评估结论；不同用途可能不同（如 Fun-ASR-Nano 做定稿时要提醒内存）
    public let verdicts: [ModelRole: String]
    public let parameters: ModelParameters
    /// 依赖的辅助模型的 id（随这个模型一起下载）
    public let dependencies: [String]
    /// 先不出现在选择框里（适配器还没做好等），但按 id 仍能找到
    public let isHidden: Bool
    /// 协议
    public let license: String

    public init(id: String, roles: Set<ModelRole>, family: ModelFamily, source: ModelSource, name: String,
                memory: String? = nil, speed: String? = nil, capabilities: ModelCapabilities? = nil,
                verdicts: [ModelRole: String] = [:], parameters: ModelParameters = ModelParameters(),
                dependencies: [String] = [], isHidden: Bool = false, license: String = "") {
        self.id = id
        self.roles = roles
        self.family = family
        self.source = source
        self.name = name
        self.memory = memory
        self.speed = speed
        self.capabilities = capabilities
        self.verdicts = verdicts
        self.parameters = parameters
        self.dependencies = dependencies
        self.isHidden = isHidden
        self.license = license
    }

    /// 需要下载时的文件清单
    public var download: LocalModel? {
        if case let .download(m) = source { m } else { nil }
    }

    public func verdict(for role: ModelRole) -> String? { verdicts[role] }
}

/// App 内置的本机模型清单，按用途分组。静态内容见 `builtIn`；测试可以构造自己的目录
public struct ModelCatalog: Sendable {
    public let models: [CatalogModel]

    public init(models: [CatalogModel]) {
        self.models = models
    }

    public func model(id: String) -> CatalogModel? {
        models.first { $0.id == id }
    }

    /// 某个用途的选择框里列出的模型（不含隐藏的），按目录顺序
    public func models(for role: ModelRole) -> [CatalogModel] {
        models.filter { $0.roles.contains(role) && !$0.isHidden }
    }

    /// 某个用途的默认模型 id；nil 表示“不用”。
    /// 会后转写：已有安装（会议目录里已有会议）保持 SpeechAnalyzer，新安装用 Fun-ASR-Nano；其他用途都用现在的模型
    public func defaultID(for role: ModelRole, isExistingInstall: Bool) -> String? {
        switch role {
        case .transcription: isExistingInstall ? ModelCatalog.speechAnalyzerID : LocalModel.funASRNano.id
        case .liveCaptions: ModelCatalog.speechAnalyzerID
        case .liveFinalize: nil
        case .minutes: LocalModel.qwen3_4B.id
        case .voiceprint: ModelCatalog.eres2netBaseID
        }
    }

    /// 模型依赖的辅助模型（目录里找不到的忽略）
    public func dependencies(of model: CatalogModel) -> [CatalogModel] {
        model.dependencies.compactMap { self.model(id: $0) }
    }

    /// 依赖这个辅助模型的其他模型
    public func dependents(of model: CatalogModel) -> [CatalogModel] {
        models.filter { $0.dependencies.contains(model.id) }
    }
}

extension ModelCatalog {
    /// SpeechAnalyzer 的 id（转写稿里一直写的就是它）
    public static let speechAnalyzerID = "apple/speechanalyzer"
    /// ERes2Net base 的 id（声纹库每人记的 `voiceprintModel` 就是它）
    public static let eres2netBaseID = "3dspeaker-eres2net-base-zh-cn-3dspeaker-16k"
    /// Silero VAD 的 id（打进 App，sherpa 整段模型切段用）
    public static let sileroVADID = "silero/vad"

    /// 本期目录。评估数据见 .scratch/model-catalog/eval/（不在仓库里）；数字来自 2026-11-17/18 的评估
    public static let builtIn = ModelCatalog(models: [
        // MARK: 会后转写 / 实时字幕 / 定稿
        CatalogModel(
            id: LocalModel.funASRNano.id, roles: [.transcription, .liveFinalize], family: .sherpaFunASRNano,
            source: .download(.funASRNano), name: "Fun-ASR-Nano",
            memory: "约 2.1 GB", speed: "20 分钟会议约 2 分钟",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .estimated, hotwords: true),
            verdicts: [
                .transcription: "最准，专业词和英文最好，热词有效",
                .liveFinalize: "更准；占约 2 GB 内存，每句定稿约晚 1 秒；8 GB 内存的机器或同时录屏时不建议",
            ],
            parameters: ModelParameters(contextTokens: 512, hotwordTokenBudget: 150),
            dependencies: [sileroVADID], license: "Apache-2.0"),
        CatalogModel(
            id: LocalModel.paraformer.id, roles: [.transcription, .liveFinalize], family: .sherpaParaformer,
            source: .download(.paraformer), name: "Paraformer",
            memory: "约 0.6 GB", speed: "20 分钟会议约 15 秒",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .real, hotwords: false),
            verdicts: [
                .transcription: "最稳，不编造、不复读；轻、快，适合内存小的机器",
                .liveFinalize: "轻、快，适合内存小的机器",
            ],
            dependencies: [LocalModel.punctuation.id, sileroVADID], license: "Apache-2.0"),
        CatalogModel(
            id: LocalModel.qwen3ASR.id, roles: [.transcription], family: .sherpaQwen3ASR,
            source: .download(.qwen3ASR), name: "Qwen3-ASR",
            memory: "约 1.9 GB", speed: "20 分钟会议约 2 分钟",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .estimated, hotwords: true),
            verdicts: [.transcription: "干净录音最准；多人会议、远场收音时可能编造内容"],
            parameters: ModelParameters(hotwordTokenBudget: 150),
            dependencies: [sileroVADID], license: "Apache-2.0"),
        CatalogModel(
            id: speechAnalyzerID, roles: [.transcription, .liveCaptions], family: .speechAnalyzer,
            source: .system, name: "SpeechAnalyzer（系统自带）",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .real, hotwords: false),
            verdicts: [
                .transcription: "不用下载；同音错字较多，热词不生效",
                .liveCaptions: "不用下载；同音错字较多",
            ],
            license: "macOS 系统组件"),
        CatalogModel(
            id: LocalModel.xASR480.id, roles: [.liveCaptions], family: .sherpaOnlineTransducer,
            source: .download(.xASR480), name: "X-ASR 480ms",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .real, hotwords: true),
            verdicts: [.liveCaptions: "比 SpeechAnalyzer 准；480ms 更跟手"],
            license: "Apache-2.0"),
        CatalogModel(
            id: LocalModel.xASR960.id, roles: [.liveCaptions], family: .sherpaOnlineTransducer,
            source: .download(.xASR960), name: "X-ASR 960ms",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .real, hotwords: true),
            verdicts: [.liveCaptions: "比 SpeechAnalyzer 准；比 480ms 略准、更省 CPU，字幕稍慢"],
            license: "Apache-2.0"),

        // MARK: 纪要
        CatalogModel(
            id: LocalModel.qwen3_4B.id, roles: [.minutes], family: .llamaGGUF,
            source: .download(.qwen3_4B), name: "Qwen3 4B（Q4_K_M）",
            memory: "约 4 GB",
            verdicts: [.minutes: "纪要在本机生成，不上传任何数据"],
            parameters: ModelParameters(contextTokens: LlamaTextGenerator.defaultContextLength),
            license: "Apache-2.0"),

        // MARK: 声纹
        CatalogModel(
            id: eres2netBaseID, roles: [.voiceprint], family: .sherpaSpeakerEmbedding,
            source: .bundled(directory: "Diarization", fileName: SherpaOnnxDiarizer.embeddingModel.name),
            name: "ERes2Net base（中文）",
            verdicts: [.voiceprint: "已打进 App，不用下载"],
            parameters: ModelParameters(matchThreshold: SherpaOnnxDiarizer.recommendedMatchThreshold),
            license: "Apache-2.0"),

        // MARK: 辅助模型（不单独让用户选，随用到它们的模型下载）
        CatalogModel(
            id: LocalModel.punctuation.id, roles: [], family: .sherpaPunctuation,
            source: .download(.punctuation), name: "标点模型", license: "Apache-2.0"),
        CatalogModel(
            id: sileroVADID, roles: [], family: .sileroVAD,
            source: .bundled(directory: "VAD", fileName: "silero_vad.onnx"), name: "Silero VAD",
            license: "MIT"),
    ])
}

/// 模型大小的文字：不到 1 GB 用整数 MB（如“76 MB”），否则一位小数 GB（和访达一样按十进制）
public func formatModelSize(_ bytes: Int64) -> String {
    bytes < 999_500_000 ? String(format: "%.0f MB", Double(bytes) / 1e6) : formatGigabytes(bytes)
}
