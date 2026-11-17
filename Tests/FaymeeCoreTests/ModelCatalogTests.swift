import Foundation
import Testing
@testable import FaymeeCore

@Suite struct ModelCatalogTests {
    let catalog = ModelCatalog.builtIn

    @Test func 每个用途至少有一个可选的模型() {
        for role in ModelRole.allCases {
            #expect(!catalog.models(for: role).isEmpty, "\(role) 没有可选的模型")
        }
    }

    @Test func id唯一() {
        let ids = catalog.models.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func 需要下载的模型_目录名唯一_文件路径在目录内且不重复() {
        let downloads = catalog.models.compactMap(\.download)
        let dirs = downloads.map(\.directoryName)
        #expect(Set(dirs).count == dirs.count)
        for m in downloads {
            let paths = m.files.map(\.path)
            #expect(Set(paths).count == paths.count, "\(m.id)")
            for f in m.files {
                #expect(!f.path.hasPrefix("/") && !f.path.contains(".."), "\(m.id) \(f.path)")
                #expect(f.size > 0 && f.sha256.count == 64 && !f.downloadURLs.isEmpty, "\(m.id) \(f.path)")
                #expect(f.downloadURLs.allSatisfy { $0.scheme == "https" }, "\(m.id) \(f.path)")
            }
            #expect(m.id == catalog.models.first { $0.download == m }?.id)
        }
    }

    @Test func 依赖的辅助模型都在目录里_且辅助模型不出现在选择框里() {
        for m in catalog.models {
            for dep in m.dependencies {
                let aux = catalog.model(id: dep)
                #expect(aux != nil, "\(m.id) 依赖的 \(dep) 不在目录里")
                #expect(aux?.roles.isEmpty == true, "\(dep) 应是辅助模型")
            }
        }
    }

    @Test func 每个用途的默认值都在目录里且能选() {
        for role in ModelRole.allCases {
            for existing in [true, false] {
                guard let id = catalog.defaultID(for: role, isExistingInstall: existing) else {
                    #expect(role.allowsNone, "\(role) 没有默认模型")
                    continue
                }
                #expect(catalog.models(for: role).contains { $0.id == id }, "\(role) 默认 \(id)")
            }
        }
    }

    @Test func 默认值_新安装转写用FunASRNano_已有安装保持SpeechAnalyzer_其他用途用现在的模型() {
        #expect(catalog.defaultID(for: .transcription, isExistingInstall: false) == "sherpa-onnx/funasr-nano-int8-2025-12-30")
        #expect(catalog.defaultID(for: .transcription, isExistingInstall: true) == "apple/speechanalyzer")
        #expect(catalog.defaultID(for: .liveCaptions, isExistingInstall: false) == "apple/speechanalyzer")
        #expect(catalog.defaultID(for: .liveFinalize, isExistingInstall: false) == nil)
        #expect(catalog.defaultID(for: .minutes, isExistingInstall: false) == LocalModel.qwen3_4B.id)
        #expect(catalog.defaultID(for: .voiceprint, isExistingInstall: false) == "3dspeaker-eres2net-base-zh-cn-3dspeaker-16k")
    }

    @Test func 纪要的Qwen3_4B仍放在模型根目录下的原位置() {
        let qwen = catalog.model(id: LocalModel.qwen3_4B.id)?.download
        #expect(qwen == LocalModel.qwen3_4B)
        #expect(qwen?.url(in: URL(fileURLWithPath: "/M")).path == "/M/Qwen3-4B-Q4_K_M.gguf")
    }

    @Test func 隐藏的模型不出现在选择框里_但按id仍能找到() {
        let hidden = CatalogModel(id: "test/hidden", roles: [.transcription], family: .sherpaQwen3ASR,
                                  source: .system, name: "隐藏", isHidden: true)
        let c = ModelCatalog(models: ModelCatalog.builtIn.models + [hidden])
        #expect(!c.models(for: .transcription).contains { $0.id == "test/hidden" })
        #expect(c.model(id: "test/hidden") != nil)
    }

    @Test func 声纹模型带自己的匹配阈值() {
        let eres = catalog.model(id: "3dspeaker-eres2net-base-zh-cn-3dspeaker-16k")
        #expect(eres?.parameters.matchThreshold == 0.7)
    }

    /// 纪要详情页按 `llama/` 前缀区分本机模型和在线模型（`Minutes.onlineModelLabel`）
    @Test func 纪要模型都是llamaGGUF_id以llama前缀开头() {
        for m in catalog.models(for: .minutes) {
            #expect(m.family == .llamaGGUF)
            #expect(m.id.hasPrefix("llama/"))
        }
    }

    @Test func Qwen3_4B带上下文长度_分段参数_关闭思考() {
        let qwen = catalog.model(id: "llama/qwen3-4b-q4km")
        #expect(qwen?.parameters.contextTokens == 8192)
        #expect(qwen?.parameters.minutesChunking
            == MinutesChunking(extractionOutput: TokenShare(2, 5), mergeOutput: TokenShare(1, 2)))
        #expect(qwen?.parameters.thinking == false)
    }

    @Test func 会后转写模型的id带本机前缀_转写稿里不当成在线引擎() {
        // 目录以后删掉的模型，旧转写稿也要按前缀认出是本机的（见 Transcript.onlineEngineLabel）
        for model in ModelCatalog.builtIn.models where model.roles.contains(.transcription) {
            #expect(model.id.hasPrefix("apple/") || model.id.hasPrefix("sherpa-onnx/"), "\(model.id)")
            let t = Transcript(engine: model.id, createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: [])
            #expect(t.onlineEngineLabel == nil, "\(model.id)")
        }
    }

    @Test func 显示的大小_不到1GB用MB() {
        #expect(formatModelSize(75_519_198) == "76 MB")
        #expect(formatModelSize(2_497_280_256) == "2.5 GB")
        #expect(formatModelSize(999_000_000) == "999 MB")
    }
}

@MainActor @Suite struct ModelSelectionsTests {
    let defaults: UserDefaults
    let suite = "FaymeeModelSelectionsTests-\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    func make(existing: Bool = false, catalog: ModelCatalog = .builtIn) -> ModelSelections {
        ModelSelections(defaults: defaults, catalog: catalog, isExistingInstall: { existing })
    }

    @Test func 没存过时按默认值决定_并立即写入_之后不再判断() {
        let s = make(existing: false)
        #expect(s.selectedID(for: .transcription) == "sherpa-onnx/funasr-nano-int8-2025-12-30")
        #expect(defaults.string(forKey: ModelSelections.key(for: .transcription)) == "sherpa-onnx/funasr-nano-int8-2025-12-30")

        // 后来有了会议也不改
        #expect(make(existing: true).selectedID(for: .transcription) == "sherpa-onnx/funasr-nano-int8-2025-12-30")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 选择变了通知每个订阅者_选同一个或选不了的不通知() {
        let s = make(existing: true)
        var first: [ModelRole] = [], second: [ModelRole] = []
        s.observe { first.append($0) }
        s.observe { second.append($0) }

        s.select("apple/speechanalyzer", for: .transcription)
        s.select("sherpa-onnx/x-asr-480ms-zh-en-punct-int8-2026-06-05", for: .transcription)
        #expect(first.isEmpty)

        s.select("sherpa-onnx/paraformer-zh-2023-09-14", for: .transcription)
        s.select(nil, for: .liveFinalize)
        s.select("sherpa-onnx/paraformer-zh-2023-09-14", for: .liveFinalize)
        #expect(first == [.transcription, .liveFinalize])
        #expect(second == first)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 已存的转写选择不被默认值覆盖_没有会议也一样() {
        // 已有安装升级时存下了 SpeechAnalyzer；之后会议都删光了（看起来像新安装）也不改成 Fun-ASR-Nano
        defaults.set("apple/speechanalyzer", forKey: ModelSelections.key(for: .transcription))
        #expect(make(existing: false).selectedID(for: .transcription) == "apple/speechanalyzer")
        defaults.set("sherpa-onnx/paraformer-zh-2023-09-14", forKey: ModelSelections.key(for: .transcription))
        #expect(make(existing: true).selectedID(for: .transcription) == "sherpa-onnx/paraformer-zh-2023-09-14")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 已有安装_转写保持SpeechAnalyzer() {
        #expect(make(existing: true).selectedID(for: .transcription) == "apple/speechanalyzer")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 选择后记住_重开后照样() {
        let s = make()
        s.select("sherpa-onnx/paraformer-zh-2023-09-14", for: .transcription)
        #expect(s.selected(for: .transcription)?.name == "Paraformer")
        #expect(make().selectedID(for: .transcription) == "sherpa-onnx/paraformer-zh-2023-09-14")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 可以不用的用途能选不用() {
        let s = make()
        #expect(s.selectedID(for: .liveFinalize) == nil)
        s.select("sherpa-onnx/paraformer-zh-2023-09-14", for: .liveFinalize)
        #expect(s.selectedID(for: .liveFinalize) == "sherpa-onnx/paraformer-zh-2023-09-14")
        s.select(nil, for: .liveFinalize)
        #expect(make().selectedID(for: .liveFinalize) == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 读到未知id时退回默认值() {
        defaults.set("sherpa-onnx/removed-model", forKey: ModelSelections.key(for: .liveCaptions))
        defaults.set("sherpa-onnx/removed-model", forKey: ModelSelections.key(for: .liveFinalize))
        let s = make(existing: true)
        #expect(s.selectedID(for: .liveCaptions) == "apple/speechanalyzer")
        #expect(s.selectedID(for: .liveFinalize) == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 存的模型不适用于这个用途时也退回默认值() {
        // 标点模型是辅助模型，不能被选作转写模型；X-ASR 只能做实时字幕
        defaults.set("sherpa-onnx/x-asr-480ms-zh-en-punct-int8-2026-06-05", forKey: ModelSelections.key(for: .transcription))
        #expect(make(existing: true).selectedID(for: .transcription) == "apple/speechanalyzer")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func 不接受不适用于该用途的选择() {
        let s = make(existing: true)
        s.select("sherpa-onnx/x-asr-480ms-zh-en-punct-int8-2026-06-05", for: .transcription)
        #expect(s.selectedID(for: .transcription) == "apple/speechanalyzer")
        defaults.removePersistentDomain(forName: suite)
    }
}
