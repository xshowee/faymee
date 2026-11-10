import FaymeeCore

/// App 用哪个纪要引擎。换引擎只改这里；name 写进每份纪要的 model，用来区分是哪个模型生成的
enum MinutesEngine {
    static func make() -> (generator: any TextGenerator, name: String) {
        (UnavailableTextGenerator(), "none")
    }
}

/// 占位引擎：接上真实模型（05 换成 llama 引擎）之前，模型一直“未下载”，
/// 纪要任务保持排队、显示“等待下载模型”，不会开始
final class UnavailableTextGenerator: TextGenerator {
    struct Unavailable: Error {}

    var contextTokens: Int { 0 }
    var isDownloaded: Bool { false }
    func countTokens(_ text: String) -> Int { text.count }
    func load(progress: @escaping (Double) -> Void) async throws { throw Unavailable() }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String { throw Unavailable() }
    func unload() {}
}
