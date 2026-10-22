// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DictFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DictFlow", path: "Sources/DictFlow")
    ]
)
