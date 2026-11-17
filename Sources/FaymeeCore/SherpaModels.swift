import Foundation

// 需要下载的 sherpa-onnx 模型：文件、大小、sha256、下载地址。
//
// - 每个文件的大小和 sha256 都与 k2-fsa/sherpa-onnx GitHub release 的官方打包（tar.bz2）里的同名文件逐字节一致
//   （2026-11-18 流式解包核对）。下载器不解 tar.bz2，所以 release 本身不作为下载地址；只用单文件地址：
//   ModelScope（国内，优先）→ Hugging Face。Hugging Face 地址钉在 commit 上
// - 有些文件只有第三方镜像（个人账号转存的官方打包）：靠 sha256 保证内容就是官方文件，镜像删了就换下一个地址
// - ModelScope 文件 API（`/api/v1/models/<仓库>/repo?Revision=master&FilePath=<路径>`）：大文件 302 到按 sha256
//   寻址的 CDN，Range 返回 206；Hugging Face `resolve/<commit>/<路径>` 302 到带签名的 CDN
// - 目录名去掉了官方打包名的 `sherpa-onnx-` 前缀；子目录（`Qwen3-0.6B/`、`tokenizer/`）与官方打包一致

private func modelScope(_ repo: String, _ path: String) -> URL {
    URL(string: "https://modelscope.cn/api/v1/models/\(repo)/repo?Revision=master&FilePath=\(path)")!
}

private func huggingFace(_ repo: String, _ commit: String, _ path: String) -> URL {
    URL(string: "https://huggingface.co/\(repo)/resolve/\(commit)/\(path)")!
}

extension LocalModel {
    /// Fun-ASR-Nano int8（sherpa-onnx `sherpa-onnx-funasr-nano-int8-2025-12-30`）。
    /// 协议：Apache-2.0（FunAudioLLM/Fun-ASR-Nano-2512；ONNX 导出 ModelScope zengshuishui/FunASR-nano-onnx 同为 Apache-2.0）。
    ///
    /// 三个 onnx 只有 ModelScope zengshuishui/FunASR-nano-onnx 一个单文件来源（sherpa 的打包取自这里）。
    /// Hugging Face csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30 是 2026-01 的旧导出，三个 onnx 字节都不同
    /// （大小 155584380 / 237792748 / 600356593），不能当备用地址。`llm.int8.onnx` 用 `llm_int8_compat/` 的
    /// 兼容版（同目录 `llm.uint8.u8u8.onnx` 字节相同，作第二个地址），不是 `llm_int8/` 的
    public static let funASRNano = LocalModel(
        id: "sherpa-onnx/funasr-nano-int8-2025-12-30",
        directoryName: "funasr-nano-int8-2025-12-30",
        files: {
            let ms = "zengshuishui/FunASR-nano-onnx"
            let hf = "csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30"
            let hfCommit = "6f16bd378457e13f36ccf3910df9017f96c346fb"
            func tokenizer(_ name: String, _ size: Int64, _ sha: String) -> ModelFile {
                ModelFile(path: "Qwen3-0.6B/\(name)", size: size, sha256: sha, downloadURLs: [
                    modelScope(ms, "Qwen3-0.6B/\(name)"), huggingFace(hf, hfCommit, "Qwen3-0.6B/\(name)"),
                ])
            }
            return [
                ModelFile(path: "encoder_adaptor.int8.onnx", size: 238_277_200,
                          sha256: "d0246c823f2c34133ae0efee395d8a189c8f92643e3432f866939ee34d34492c",
                          downloadURLs: [modelScope(ms, "encoder_adaptor.int8.onnx")]),
                ModelFile(path: "llm.int8.onnx", size: 600_339_316,
                          sha256: "7f0c5a508b41474b1b1ec1cdbdefafd2cf8b3642c6915a0a425265b7b7d2c960",
                          downloadURLs: [modelScope(ms, "llm_int8_compat/llm.int8.onnx"),
                                         modelScope(ms, "llm_int8_compat/llm.uint8.u8u8.onnx")]),
                ModelFile(path: "embedding.int8.onnx", size: 155_583_106,
                          sha256: "a05d2816e284fcca29a5dccb2c14b9edeb638fd983a84cd4a447248889b6a408",
                          downloadURLs: [modelScope(ms, "embedding.int8.onnx")]),
                tokenizer("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                tokenizer("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                tokenizer("merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            ]
        }())

    /// Paraformer 中文（sherpa-onnx `sherpa-onnx-paraformer-zh-2023-09-14`）。**必须用这一版**：2024-03-09 和
    /// 2025-10-07 版没有逐字时间。协议：Apache-2.0（iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch；
    /// Hugging Face csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14 标 apache-2.0）。
    /// 国内镜像是第三方转存（ModelScope xnnehang、HZZSCIENCE），与官方打包逐字节一致
    public static let paraformer = LocalModel(
        id: "sherpa-onnx/paraformer-zh-2023-09-14",
        directoryName: "paraformer-zh-2023-09-14",
        files: {
            func file(_ path: String, _ size: Int64, _ sha: String) -> ModelFile {
                ModelFile(path: path, size: size, sha256: sha, downloadURLs: [
                    modelScope("xnnehang/sherpa-onnx-paraformer-zh-2023-09-14", path),
                    modelScope("HZZSCIENCE/sherpa-onnx-paraformer-zh-2023-09-14", path),
                    huggingFace("csukuangfj/sherpa-onnx-paraformer-zh-2023-09-14",
                                "def027084691107096b5ebba69785756d63de6c5", path),
                ])
            }
            return [
                file("model.int8.onnx", 243_371_218, "f36a0433bcf096bd6d6f11b80a3ac8bed110bdca632fe0d731df8d1a84475945"),
                file("tokens.txt", 75_756, "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6"),
            ]
        }())

    /// 标点（CT-Transformer 中英，int8；sherpa-onnx `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8`）。
    /// Paraformer 的辅助模型。sherpa-onnx 只需要 `model.int8.onnx`（词表在模型的 metadata 里）。
    /// 协议：Apache-2.0（原模型 iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch）。
    ///
    /// int8 版官方只在 GitHub release 的 tar.bz2 里（Hugging Face csukuangfj 只有 294MB 的 fp32 版）。
    /// 这里用第三方转存的单文件（ModelScope ranger810、AlexZh；Hugging Face ranger810、lorneluo），
    /// 与官方打包里的文件逐字节一致（ticket 01 的 Comments 记了取舍）
    public static let punctuation = LocalModel(
        id: "sherpa-onnx/punct-ct-transformer-zh-en-int8-2024-04-12",
        directoryName: "punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8",
        files: [
            ModelFile(path: "model.int8.onnx", size: 75_519_198,
                      sha256: "65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1",
                      downloadURLs: [
                          modelScope("ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8",
                                     "model.int8.onnx"),
                          modelScope("AlexZh/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8",
                                     "model.int8.onnx"),
                          huggingFace("ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8",
                                      "5cccf43af83e4fc50d1d55b8410312e87709be70", "model.int8.onnx"),
                          huggingFace("lorneluo/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8",
                                      "fc2be466e3c11927b306a31cdee23c9c38da44cc", "model.int8.onnx"),
                      ]),
        ])

    /// Qwen3-ASR 0.6B int8（sherpa-onnx `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25`）。
    /// 协议：Apache-2.0（Qwen/Qwen3-ASR-0.6B；ONNX 导出 ModelScope zengshuishui/Qwen3-ASR-onnx 同为 Apache-2.0）。
    /// ModelScope zengshuishui/Qwen3-ASR-onnx 是 sherpa 打包的来源（文件在 `model_0.6B/` 下）；
    /// Hugging Face csukuangfj2（sherpa-onnx 作者的账号）有同样字节的单文件
    public static let qwen3ASR = LocalModel(
        id: "sherpa-onnx/qwen3-asr-0.6B-int8-2026-03-25",
        directoryName: "qwen3-asr-0.6B-int8-2026-03-25",
        files: {
            func file(_ path: String, msPath: String, _ size: Int64, _ sha: String) -> ModelFile {
                ModelFile(path: path, size: size, sha256: sha, downloadURLs: [
                    modelScope("zengshuishui/Qwen3-ASR-onnx", msPath),
                    huggingFace("csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
                                "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a", path),
                ])
            }
            return [
                file("conv_frontend.onnx", msPath: "model_0.6B/conv_frontend.onnx", 44_148_281,
                     "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e"),
                file("encoder.int8.onnx", msPath: "model_0.6B/encoder.int8.onnx", 182_491_662,
                     "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9"),
                file("decoder.int8.onnx", msPath: "model_0.6B/decoder.int8.onnx", 755_914_231,
                     "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771"),
                file("tokenizer/vocab.json", msPath: "tokenizer/vocab.json", 2_776_833,
                     "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                file("tokenizer/merges.txt", msPath: "tokenizer/merges.txt", 1_671_853,
                     "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                file("tokenizer/tokenizer_config.json", msPath: "tokenizer/tokenizer_config.json", 12_487,
                     "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            ]
        }())

    /// X-ASR 流式 480ms，带标点的 int8 版（sherpa-onnx
    /// `sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05`）。
    /// 协议：Apache-2.0（官方 GilgameshWind/X-ASR-zh-en）。
    ///
    /// 官方仓库（Hugging Face GilgameshWind/X-ASR-zh-en、modelscope.ai Gilgamesh-J/X-ASR-zh-en）只有 fp32、不带标点的版本，
    /// decoder 字节也不同；带标点的 int8 版只在 sherpa 的 GitHub release 打包里。这里用第三方转存
    /// （ModelScope bujidc、yangchen1258；Hugging Face lorneluo），与官方打包逐字节一致。
    /// `tokens.txt` 与官方仓库的相同，官方仓库作最后的地址
    public static let xASR480 = xASR(chunk: "480ms", encoderSize: 155_278_641,
                                     encoderSHA: "908596dcc137a73b95be908ca55e88caa1b3dbbe8027c171615f4b0609c5eb1e",
                                     encoderMirrors: ["bujidc", "yangchen1258"], encoderLorneluo: true)

    /// X-ASR 流式 960ms，带标点的 int8 版。来源、协议同 480ms。除 encoder 外的文件与 480ms 版逐字节相同，
    /// 所以也从 480ms 的镜像取；encoder 目前只有 ModelScope bujidc 一个来源
    public static let xASR960 = xASR(chunk: "960ms", encoderSize: 155_276_576,
                                     encoderSHA: "017e3cf23097302dbc57ebd72cf4a209cf55c367920669e2d9ce9c0381a96ddd",
                                     encoderMirrors: ["bujidc"], encoderLorneluo: false)

    private static func xASR(chunk: String, encoderSize: Int64, encoderSHA: String, encoderMirrors: [String],
                             encoderLorneluo: Bool) -> LocalModel {
        let name = "x-asr-\(chunk)-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
        let name480 = "x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
        let lorneluo = ("lorneluo/sherpa-onnx-\(name480)", "4b86b17a5b96dcf6026a73e2239271faa9d6f5df")
        /// 同一个 chunk 的镜像优先，再用 480ms 的镜像（共有的文件字节相同）
        func shared(_ path: String, lorneluoHasIt: Bool, extra: [URL] = []) -> [URL] {
            var urls = ["bujidc", "yangchen1258"].map { modelScope("\($0)/sherpa-onnx-\(name)", path) }
            if chunk != "480ms" {
                urls = [modelScope("bujidc/sherpa-onnx-\(name)", path)]
                    + ["bujidc", "yangchen1258"].map { modelScope("\($0)/sherpa-onnx-\(name480)", path) }
            }
            if lorneluoHasIt { urls.append(huggingFace(lorneluo.0, lorneluo.1, path)) }
            return urls + extra
        }
        var encoderURLs = encoderMirrors.map { modelScope("\($0)/sherpa-onnx-\(name)", "encoder.int8.onnx") }
        if encoderLorneluo { encoderURLs.append(huggingFace(lorneluo.0, lorneluo.1, "encoder.int8.onnx")) }
        let officialTokens = huggingFace("GilgameshWind/X-ASR-zh-en", "689ff18c584d29910da37b6fe904db0c1489c9d1",
                                         "deployment/models/chunk-\(chunk)-model/tokens.txt")
        return LocalModel(
            id: "sherpa-onnx/x-asr-\(chunk)-zh-en-punct-int8-2026-06-05",
            directoryName: name,
            files: [
                ModelFile(path: "encoder.int8.onnx", size: encoderSize, sha256: encoderSHA, downloadURLs: encoderURLs),
                ModelFile(path: "decoder.onnx", size: 11_309_084,
                          sha256: "a1cbc9eac2d5e3fb6617a218c67ad6daaa7f4e0fd225f08b2c22ab0413c8c257",
                          downloadURLs: shared("decoder.onnx", lorneluoHasIt: true)),
                ModelFile(path: "joiner.int8.onnx", size: 2_581_422,
                          sha256: "aedb7fa697b2ab43f20499826fff7c997eea7d67db77be97769aeeeb726e63b3",
                          downloadURLs: shared("joiner.int8.onnx", lorneluoHasIt: true)),
                ModelFile(path: "tokens.txt", size: 58_806,
                          sha256: "b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c",
                          downloadURLs: shared("tokens.txt", lorneluoHasIt: true, extra: [officialTokens])),
                // 热词要用（modified_beam_search）
                ModelFile(path: "bpe.model", size: 119_265,
                          sha256: "f87a38025a5fdd1e4e9591f6a44bb81295097ce0b80df6f4ab9f44e52c64ca5f",
                          downloadURLs: shared("bpe.model", lorneluoHasIt: false)),
            ])
    }
}
