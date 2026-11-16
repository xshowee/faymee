import FaymeeCore

/// App 用哪个纪要引擎、哪个模型文件。按设置在本机 `llama.cpp` 与在线大模型之间切换；
/// name 写进每份纪要的 model，用来区分是哪个模型生成的。
/// 模型文件由 ModelDownloader 下到同一个约定目录，引擎和下载器都按 LocalModel 找文件
enum MinutesEngine {
    static let model = LocalModel.qwen3_4B
    /// 模型放在哪个目录。下载器和引擎必须用同一个
    static let directory = LocalModel.defaultDirectory

    @MainActor
    static func make(
        settings: OnlineModelSettings,
        transport: any HTTPTransport
    ) -> (generator: any TextGenerator, name: String, requiresPower: Bool, isOnline: Bool) {
        OnlineMinutesEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: { (LlamaTextGenerator(model: model, directory: directory), model.id) }
        )
    }

    @MainActor static func makeDownloader() -> ModelDownloader {
        ModelDownloader(model: model, directory: directory, transport: URLSessionModelTransport())
    }
}
