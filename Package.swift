// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Faymee",
    platforms: [.macOS(.v26)],
    targets: [
        // llama.cpp 官方预编译 xcframework（b12110 = 稳定版 v0.9.0）。动态 framework，Metal shader 内嵌；
        // build.sh 把它拷进 Faymee.app/Contents/Frameworks 并重签。升级：看 vX.Y.Z 的 nightly-tag.txt，
        // 取对应 bNNNNN 的 xcframework，checksum 用 `swift package compute-checksum` 算
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12110/llama-b12110-xcframework.zip",
            checksum: "fca702506b04cba11c7f1226056371d16ddfa80e1248da979166a1eec36c415f"
        ),
        // sherpa-onnx 官方预编译静态 xcframework（C API，不含 onnxruntime）+ 维护者另发的 onnxruntime 静态
        // xcframework（版本取自 sherpa-onnx v2.0.1 的 Package.swift）。静态链接，build.sh 不用拷 framework。
        // 区分说话人用，模型文件见 scripts/fetch-diarization-models.sh
        .binaryTarget(
            name: "SherpaOnnxC",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-macos-static.xcframework.zip",
            checksum: "3c378789ebcbf3b1fb2e7cf0c58dae8e5629001598148aee2edd4494dc939a27"
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip",
            checksum: "cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0"
        ),
        // 非界面代码：数据模型、存储、整理。不声明 library product，静态链接进 App
        .target(name: "FaymeeCore", dependencies: ["llama", "SherpaOnnxC", "onnxruntime"], path: "Sources/FaymeeCore",
                linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Network"), .linkedLibrary("c++")]),
        .executableTarget(name: "Faymee", dependencies: ["FaymeeCore"], path: "Sources/Faymee"),
        // Resources/ 放契约测试用的真实录音
        .testTarget(name: "FaymeeCoreTests", dependencies: ["FaymeeCore"], path: "Tests/FaymeeCoreTests",
                    resources: [.copy("Resources")]),
    ],
    swiftLanguageModes: [.v5]
)
