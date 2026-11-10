import FaymeeCore

/// App 用哪个纪要引擎、哪个模型文件。换引擎只改这里；name 写进每份纪要的 model，用来区分是哪个模型生成的。
/// 模型文件由 ModelDownloader 下到同一个约定目录，引擎和下载器都按 LocalModel 找文件
enum MinutesEngine {
    static let model = LocalModel.qwen3_4B
    /// 模型放在哪个目录。下载器和引擎必须用同一个
    static let directory = LocalModel.defaultDirectory

    static func make() -> (generator: any TextGenerator, name: String) {
        (LlamaTextGenerator(model: model, directory: directory), model.id)
    }

    @MainActor static func makeDownloader() -> ModelDownloader {
        ModelDownloader(model: model, directory: directory, transport: URLSessionModelTransport())
    }
}
