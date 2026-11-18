import Foundation

/// 整段识别模型（会后转写、实时字幕定稿共用）一个家族的适配器：怎么加载识别器、热词怎么按 tokenizer 截、
/// 输出要不要套防护。文件位置不在这里：由 `SegmentRecognizerLoader` 按目录项自己的 `download` 给出。
///
/// 家族 → 适配器只在 `ModelFamily.segmentRecognizer` 一处对应。同一家族加新模型只加目录项（文件布局与同家族一致）；
/// 加新家族在那里加一项
public struct SegmentRecognizerAdapter: Sendable {
    /// 加载一个识别器要的东西。目录都来自目录项（和它依赖的辅助模型）的 `download`
    public struct Request: Sendable, Equatable {
        /// 目录项自己的模型目录
        public var directory: URL
        /// 标点模型的目录（Paraformer 依赖它；其他家族为 nil）
        public var punctuationDirectory: URL?
        /// 错误信息里的模型名（目录项的 `name`）
        public var name: String
        /// 上下文窗口（目录项的 `contextTokens`）；nil 用 sherpa 的默认值
        public var contextTokens: Int?
        /// 已按预算截好的热词
        public var hotwords: [String]
        public var threads: Int
    }

    /// 建识别器（加载 sherpa 模型）。只在文件按大小确认齐全后调用：坏文件会让 sherpa-onnx `_Exit` 整个进程
    public typealias Load = @Sendable (Request) throws -> any SegmentRecognizer

    /// 热词按模型自己的 tokenizer 计数截到预算内
    public struct HotwordFitting: Sendable {
        /// tokenizer 目录（相对模型目录，含 merges.txt）
        let tokenizer: String
        /// sherpa 把热词拼进提示词时用的分隔（Fun-ASR-Nano `, `，Qwen3-ASR 空格），按这个拼法计数
        let separator: String

        /// 按热词表顺序放，放不下就停。热词先去掉 sherpa 的分隔符（`SherpaHotwords.sanitize`）
        public func fit(_ hotwords: [String], budget: Int, modelDirectory: URL) throws -> [String] {
            let words = SherpaHotwords.sanitize(hotwords)
            guard !words.isEmpty else { return [] }
            let counter = try QwenTokenCounter(directory: modelDirectory.appendingPathComponent(tokenizer))
            return HotwordBudget.fit(words, budget: budget, separator: separator, count: counter.count)
        }
    }

    let load: Load
    /// 热词要按预算截（这样的家族的目录项必须带 `hotwordTokenBudget`）；nil 是不用热词
    public let hotwordFitting: HotwordFitting?
    /// 依赖标点模型（目录项的依赖里要有 `.sherpaPunctuation` 家族的一项）
    let needsPunctuation: Bool
    /// 输出套 `GuardedRecognizer`（大模型类 ASR 的复读、日文、提示词泄漏）
    let guarded: Bool

    /// 换掉加载（测试用：不加载真模型，看拿到的文件位置）
    func replacingLoad(_ load: @escaping Load) -> SegmentRecognizerAdapter {
        SegmentRecognizerAdapter(load: load, hotwordFitting: hotwordFitting, needsPunctuation: needsPunctuation,
                                 guarded: guarded)
    }
}

extension SegmentRecognizerAdapter {
    static let paraformer = SegmentRecognizerAdapter(
        load: { r in
            guard let punctuation = r.punctuationDirectory else { throw SherpaModelError.engineUnavailable(model: r.name) }
            return try ParaformerRecognizer(directory: r.directory, punctuationDirectory: punctuation, name: r.name,
                                            threads: r.threads)
        },
        hotwordFitting: nil, needsPunctuation: true, guarded: false)

    static let funASRNano = SegmentRecognizerAdapter(
        load: { r in
            try FunASRNanoRecognizer(directory: r.directory, name: r.name, hotwords: r.hotwords, threads: r.threads)
        },
        hotwordFitting: HotwordFitting(tokenizer: "Qwen3-0.6B", separator: ", "), needsPunctuation: false,
        guarded: true)

    static let qwen3ASR = SegmentRecognizerAdapter(
        load: { r in
            try Qwen3ASRRecognizer(directory: r.directory, name: r.name, contextTokens: r.contextTokens,
                                   hotwords: r.hotwords, threads: r.threads)
        },
        hotwordFitting: HotwordFitting(tokenizer: "tokenizer", separator: " "), needsPunctuation: false,
        guarded: true)
}

extension ModelFamily {
    /// 整段识别家族的适配器；其他家族为 nil。家族 → 适配器只在这里对应
    public var segmentRecognizer: SegmentRecognizerAdapter? {
        switch self {
        case .sherpaParaformer: .paraformer
        case .sherpaFunASRNano: .funASRNano
        case .sherpaQwen3ASR: .qwen3ASR
        case .speechAnalyzer, .sherpaOnlineTransducer, .llamaGGUF, .sherpaSpeakerEmbedding, .sherpaPunctuation,
             .sileroVAD: nil
        }
    }
}

/// 一个目录项的整段识别器：文件取自目录项自己的 `download` 和它依赖的辅助模型，热词按目录项的预算截。
/// 会后转写、实时字幕定稿、热词页都从这里拿，不按模型写死文件位置
public struct SegmentRecognizerLoader: Sendable {
    public let model: CatalogModel
    /// 目录项所在的目录（找依赖的辅助模型）
    public let catalog: ModelCatalog
    /// 模型根目录
    public let modelDirectory: URL
    let adapter: SegmentRecognizerAdapter
    /// 要按大小确认齐全的模型（目录项和需要下载的辅助模型），带错误信息里的名字
    private let required: [Required]
    private let punctuationDirectory: URL?

    private struct Required: Sendable {
        let name: String
        let model: LocalModel
    }

    /// 目录项不是整段识别家族、不用下载，或依赖的辅助模型不在目录里时为 nil
    /// - Parameter modelDirectory: 模型根目录（`LocalModel.defaultDirectory`）
    public init?(model: CatalogModel, catalog: ModelCatalog = .builtIn,
                 modelDirectory: URL = LocalModel.defaultDirectory) {
        self.init(model: model, catalog: catalog, modelDirectory: modelDirectory, adapter: \.segmentRecognizer)
    }

    /// 测试用：`adapter` 代替 `ModelFamily.segmentRecognizer`（换掉加载）
    init?(model: CatalogModel, catalog: ModelCatalog, modelDirectory: URL,
          adapter: (ModelFamily) -> SegmentRecognizerAdapter?) {
        guard let adapter = adapter(model.family), model.download != nil else { return nil }
        let dependencies = catalog.dependencies(of: model)
        var punctuationDirectory: URL?
        if adapter.needsPunctuation {
            guard let punctuation = dependencies.first(where: { $0.family == .sherpaPunctuation })?.download else {
                return nil
            }
            punctuationDirectory = punctuation.directory(in: modelDirectory)
        }
        self.model = model
        self.catalog = catalog
        self.adapter = adapter
        required = ([model] + dependencies).compactMap { m in m.download.map { Required(name: m.name, model: $0) } }
        self.modelDirectory = modelDirectory
        self.punctuationDirectory = punctuationDirectory
    }

    /// 目录项（含辅助模型）的文件都在、大小对
    public var isDownloaded: Bool { required.allSatisfy { $0.model.isDownloaded(in: modelDirectory) } }

    /// 按大小确认文件齐全，缺了抛 `SherpaModelError`
    public func checkFiles() throws {
        for r in required { try r.model.checkFiles(name: r.name, in: modelDirectory) }
    }

    /// 目录项自己的模型目录
    private var directory: URL { model.download!.directory(in: modelDirectory) }

    /// 热词截到目录项的预算内。家族不用热词时为空；返回值第二项是去掉空词、重复后的热词数
    public func fitHotwords(_ hotwords: [String]) throws -> (fitted: [String], total: Int) {
        guard let fitting = adapter.hotwordFitting else { return ([], 0) }
        // 这样的目录项一定带预算（`CatalogModel.init` 里查过）
        let budget = model.parameters.hotwordTokenBudget!
        return (try fitting.fit(hotwords, budget: budget, modelDirectory: directory),
                SherpaHotwords.sanitize(hotwords).count)
    }

    /// 建识别器：先按大小确认文件齐全（会中、转写前都可能被删），再截热词、加载，大模型类 ASR 套上输出防护。
    /// 加载可能要几秒，在后台线程上调用
    public func makeRecognizer(hotwords: [String], threads: Int) throws -> any SegmentRecognizer {
        try checkFiles()
        let request = SegmentRecognizerAdapter.Request(
            directory: directory, punctuationDirectory: punctuationDirectory, name: model.name,
            contextTokens: model.parameters.contextTokens, hotwords: try fitHotwords(hotwords).fitted,
            threads: threads)
        let recognizer = try adapter.load(request)
        return adapter.guarded ? GuardedRecognizer(recognizer) : recognizer
    }
}

/// 交给 sherpa 大模型类 ASR（Fun-ASR-Nano、Qwen3-ASR）的热词
enum SherpaHotwords {
    /// sherpa 按 `,` `;` `，` `；` 和换行、制表符拆热词：热词里的这些字符换成空格，免得一个词被拆开；再去掉空词、重复
    static func sanitize(_ hotwords: [String]) -> [String] {
        Hotwords.normalize(hotwords.map { word in String(word.map { ",;，；\n\r\t".contains($0) ? " " : $0 }) })
    }

    /// 交给 sherpa 的 `hotwords` 参数：逗号连接（sherpa 拆开后按各家族的拼法拼进提示词）
    static func argument(_ hotwords: [String]) -> String {
        sanitize(hotwords).joined(separator: ",")
    }
}
