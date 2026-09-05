// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimpleWhisper",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "SimpleWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/SimpleWhisper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
