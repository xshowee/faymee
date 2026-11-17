import Foundation

/// 把设置里「声纹」用途选中的模型同步到转写管线的区分引擎和匹配阈值（`TranscriptionPipeline.setDiarizer`）。
///
/// - 选择变化、所选模型下载完成或被删除时重建引擎；正在区分的那一场用旧模型跑完，之后的用新模型
/// - 所选模型还不能用（需要下载但没下完、打进 App 的文件不在）时管线没有区分引擎：
///   之后的完整转写跳过区分说话人（不算失败），也不能单独区分，下好后自动恢复
/// - 声纹类模型只有「声纹」一个用途，它们下载器的 `onAvailabilityChange` 由这里占用
@MainActor
public final class VoiceprintModelBinding {
    private let selections: ModelSelections
    private let downloads: ModelDownloads
    private let bundleResources: URL?
    private weak var pipeline: TranscriptionPipeline?
    /// 上次交给管线的（模型 id，是否有引擎）。没变时不重建引擎，免得每次都重新校验模型哈希
    private var applied: (id: String?, available: Bool)?

    /// - Parameter bundleResources: App 的 `Contents/Resources`（`Bundle.main.resourceURL`），打进 App 的模型在这下面
    public init(selections: ModelSelections, downloads: ModelDownloads, bundleResources: URL?) {
        self.selections = selections
        self.downloads = downloads
        self.bundleResources = bundleResources
    }

    /// 所选模型现在的区分引擎（nil 是现在不能用）和它的匹配阈值。建管线时用它给初值
    public func makeEngine() -> (diarizer: (any SpeakerDiarizer)?, voiceprintThreshold: Float) {
        let engine = SherpaOnnxDiarizer.engine(for: selections.selected(for: .voiceprint),
                                               bundleResources: bundleResources, modelsRoot: downloads.directory)
        return (engine.diarizer, engine.voiceprintThreshold)
    }

    /// 开始同步：记下管线现在用的模型，之后选择或下载状态变化时换引擎
    public func bind(_ pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
        applied = (selections.selectedID(for: .voiceprint), pipeline.canDiarize)
        for model in downloads.catalog.models(for: .voiceprint) {
            downloads.downloader(for: model)?.onAvailabilityChange = { [weak self] in self?.sync() }
        }
        selections.observe { [weak self] role in
            if role == .voiceprint { self?.sync() }
        }
    }

    /// 选择或下载状态可能变了：所选模型或它能不能用变了才换引擎
    public func sync() {
        guard let pipeline else { return }
        let id = selections.selectedID(for: .voiceprint)
        let engine = makeEngine()
        guard applied?.id != id || applied?.available != (engine.diarizer != nil) else { return }
        applied = (id, engine.diarizer != nil)
        pipeline.setDiarizer(engine.diarizer, voiceprintThreshold: engine.voiceprintThreshold)
    }
}
