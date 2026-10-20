// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kadr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kadr", path: "Sources/Kadr")
    ]
)
