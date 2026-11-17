import Foundation

/// 把设置里「声纹」用途选中的模型同步到转写管线的区分引擎和匹配阈值（`TranscriptionPipeline.setDiarizer`）。
///
/// - 选择变化、所选模型下载完成或被删除时重建引擎；正在区分的那一场用旧模型跑完，之后的用新模型
/// - 所选模型需要下载但没下完时管线没有区分引擎、在等它（spec「切换的语义」）：区分说话人排队「等待下载声纹模型」，
///   转写照常；下载完成时换上引擎，排队的自动开始
/// - 打进 App 的文件不在（`swift run` 等）时没有引擎、也不等：之后的完整转写跳过区分说话人，不能单独区分
/// - 订阅声纹模型下载器的可用性变化（`ModelDownloader.observeAvailability`）
@MainActor
public final class VoiceprintModelBinding {
    private let selections: ModelSelections
    private let downloads: ModelDownloads
    private let bundleResources: URL?
    private weak var pipeline: TranscriptionPipeline?
    /// 上次交给管线的（模型 id，是否有引擎）。没变时不重建引擎，免得每次都重新校验模型哈希。
    /// 等不等下载由这两样决定，不用另记
    private var applied: (id: String?, available: Bool)?

    /// - Parameter bundleResources: App 的 `Contents/Resources`（`Bundle.main.resourceURL`），打进 App 的模型在这下面
    public init(selections: ModelSelections, downloads: ModelDownloads, bundleResources: URL?) {
        self.selections = selections
        self.downloads = downloads
        self.bundleResources = bundleResources
    }

    /// 所选模型现在的区分引擎（nil 是现在不能用）、它的匹配阈值，和没有引擎时在等什么
    /// （所选模型需要下载、还没下完时是等下载它；否则 nil）。建管线时用它给初值
    public func makeEngine() -> (diarizer: (any SpeakerDiarizer)?, voiceprintThreshold: Float,
                                 waitReason: TranscriptionWaitReason?) {
        let selected = selections.selected(for: .voiceprint)
        let engine = SherpaOnnxDiarizer.engine(for: selected, bundleResources: bundleResources,
                                               modelsRoot: downloads.directory)
        var waitReason: TranscriptionWaitReason?
        if engine.diarizer == nil, let selected, case .download = selected.source {
            waitReason = .modelDownload(id: selected.id)
        }
        return (engine.diarizer, engine.voiceprintThreshold, waitReason)
    }

    /// 所选模型的声纹提取（重算声纹库用）；所选模型现在不能用时为 nil
    public func makeExtractor() -> (any VoiceprintExtractor)? {
        SherpaOnnxDiarizer.engine(for: selections.selected(for: .voiceprint), bundleResources: bundleResources,
                                  modelsRoot: downloads.directory).diarizer
    }

    /// 开始同步：记下管线现在用的模型，之后选择或下载状态变化时换引擎
    public func bind(_ pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
        // 看有没有引擎，不看 canDiarize：等下载时 canDiarize 也为 true，下好时就看不出变化了
        applied = (selections.selectedID(for: .voiceprint), pipeline.voiceprintModel != nil)
        for model in downloads.catalog.models(for: .voiceprint) {
            downloads.downloader(for: model)?.observeAvailability { [weak self] in self?.sync() }
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
        pipeline.setDiarizer(engine.diarizer, voiceprintThreshold: engine.voiceprintThreshold,
                             waitReason: engine.waitReason)
    }
}
