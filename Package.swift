// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kadr",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Kadr", path: "Sources/Kadr"),
        // `swift test`: Swift Testing comes with the Command Line Tools, no Xcode needed.
        .testTarget(name: "KadrTests", dependencies: ["Kadr"], path: "Tests/KadrTests")
    ]
)
