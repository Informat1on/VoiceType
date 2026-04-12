// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceType", targets: ["VoiceType"])
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "VoiceType",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper")
            ],
            path: "Sources/VoiceType",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
