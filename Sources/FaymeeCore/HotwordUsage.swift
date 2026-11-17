import Foundation

/// 热词表对会后转写所选本机模型起多大作用，热词页据此提示（只在本机转写时有意义）
public enum HotwordUsage: Hashable, Sendable {
    /// 模型不用热词表（Paraformer、SpeechAnalyzer）
    case unused(model: String)
    /// 全部生效（或热词表是空的）
    case all
    /// 超出模型的热词预算：只有前 `used` 个交给模型
    case partial(model: String, used: Int, total: Int)
    /// 算不出来（模型还没下载，没有 tokenizer）
    case unknown

    /// 按模型的能力和热词预算判断。要读 tokenizer（约 0.1 秒），不要在主线程上逐字调用
    /// - Parameter modelDirectory: 模型根目录（`LocalModel.defaultDirectory`）
    public init(model: CatalogModel, hotwords: [String], modelDirectory: URL) {
        guard model.capabilities?.hotwords == true else {
            self = .unused(model: model.name)
            return
        }
        guard let budget = model.parameters.hotwordTokenBudget else {
            self = .all
            return
        }
        // 按家族用模型自己的 tokenizer 截断（和转写时一样）；新家族支持热词预算时在这加分支
        let fitted: (used: Int, total: Int)?
        switch model.family {
        case .sherpaFunASRNano:
            let local = LocalModel.funASRNano
            fitted = local.isDownloaded(in: modelDirectory)
                ? (try? FunASRNano.fitHotwords(hotwords, budget: budget,
                                               modelDirectory: local.directory(in: modelDirectory)))
                    .map { ($0.count, FunASRNano.sanitize(hotwords).count) }
                : nil
        case .sherpaQwen3ASR:
            let local = LocalModel.qwen3ASR
            fitted = local.isDownloaded(in: modelDirectory)
                ? (try? Qwen3ASR.fitHotwords(hotwords, budget: budget, modelDirectory: local.directory(in: modelDirectory)))
                    .map { ($0.count, Qwen3ASR.sanitizedHotwords(hotwords).count) }
                : nil
        default:
            fitted = nil
        }
        guard let fitted else {
            self = .unknown
            return
        }
        self = fitted.used < fitted.total ? .partial(model: model.name, used: fitted.used, total: fitted.total) : .all
    }

    /// 热词页上的一句提示；不用提示时为 nil
    public var note: String? {
        switch self {
        case let .unused(model): "当前模型（\(model)）不使用热词表"
        case let .partial(model, used, total): "热词太多：当前模型（\(model)）只用得上前 \(used) 个，后面 \(total - used) 个不生效"
        case .all, .unknown: nil
        }
    }
}
