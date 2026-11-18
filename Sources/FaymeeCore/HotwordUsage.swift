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
        // 用模型自己的 tokenizer 按它的预算截断（和转写时一样）；家族不按预算截热词时全部生效
        guard let loader = SegmentRecognizerLoader(model: model, modelDirectory: modelDirectory),
              loader.adapter.hotwordFitting != nil else {
            self = .all
            return
        }
        guard loader.isDownloaded, let fitted = try? loader.fitHotwords(hotwords) else {
            self = .unknown
            return
        }
        self = fitted.fitted.count < fitted.total
            ? .partial(model: model.name, used: fitted.fitted.count, total: fitted.total) : .all
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
