// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Faymee",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Faymee", path: "Sources/Faymee")
    ],
    swiftLanguageModes: [.v5]
)
