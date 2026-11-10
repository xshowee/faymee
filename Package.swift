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
        // 非界面代码：数据模型、存储、整理。不声明 library product，静态链接进 App
        .target(name: "FaymeeCore", dependencies: ["llama"], path: "Sources/FaymeeCore"),
        .executableTarget(name: "Faymee", dependencies: ["FaymeeCore"], path: "Sources/Faymee"),
        // Resources/ 放契约测试用的真实录音
        .testTarget(name: "FaymeeCoreTests", dependencies: ["FaymeeCore"], path: "Tests/FaymeeCoreTests",
                    resources: [.copy("Resources")]),
    ],
    swiftLanguageModes: [.v5]
)
