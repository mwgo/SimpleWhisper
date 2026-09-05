// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SimpleWhisper",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "SimpleWhisper",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SimpleWhisper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
