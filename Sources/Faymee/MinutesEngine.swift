import FaymeeCore

/// App 用哪个纪要引擎。按设置在本机 `llama.cpp` 与在线大模型之间切换；本机时用「纪要」用途选中的目录项。
/// name 写进每份纪要的 model，用来区分是哪个模型生成的（本机是目录项 id，都以 `llama/` 开头）。
/// 模型文件由 `ModelDownloads` 里这个目录项的下载器下到同一个约定目录，引擎和下载器都按 LocalModel 找文件
enum MinutesEngine {
    /// 模型放在哪个目录。下载器和引擎必须用同一个
    static let directory = LocalModel.defaultDirectory

    /// 选中的本机纪要模型；选择里没有时（不会发生，「纪要」没有“不用”）用目录默认
    @MainActor
    static func selectedModel(_ selections: ModelSelections) -> CatalogModel {
        let catalog = selections.catalog
        return selections.selected(for: .minutes)
            ?? catalog.model(id: catalog.defaultID(for: .minutes, isExistingInstall: true)!)!
    }

    @MainActor
    static func make(
        settings: OnlineModelSettings,
        transport: any HTTPTransport,
        selections: ModelSelections
    ) -> (generator: any TextGenerator, name: String, requiresPower: Bool, isOnline: Bool) {
        OnlineMinutesEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: {
                let model = selectedModel(selections)
                return (LlamaTextGenerator(catalogModel: model, directory: directory), model.id)
            }
        )
    }
}
