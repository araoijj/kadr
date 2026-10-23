// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kadr",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Kadr", path: "Sources/Kadr")
    ]
)
