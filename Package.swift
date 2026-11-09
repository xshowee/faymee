// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Faymee",
    platforms: [.macOS(.v26)],
    targets: [
        // 非界面代码：数据模型、存储、整理。不声明 library product，静态链接进 App，
        // build.sh 只需拷贝一个可执行文件
        .target(name: "FaymeeCore", path: "Sources/FaymeeCore"),
        .executableTarget(name: "Faymee", dependencies: ["FaymeeCore"], path: "Sources/Faymee"),
    ],
    swiftLanguageModes: [.v5]
)
