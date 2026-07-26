// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceType", targets: ["VoiceType"])
    ],
    dependencies: [
        // Pinned to a revision, not a branch: a moving branch means two builds of the
        // same VoiceType version can ship different whisper.cpp revisions.
        // Not `exact:` — SwiftPM rejects unsafeFlags in version-pinned dependencies,
        // and the fork needs them (-fno-objc-arc for ggml-metal, -fobjc-arc for CoreML).
        // This revision is tagged v1.9.1-vt.2 in the fork.
        .package(url: "https://github.com/Informat1on/SwiftWhisper.git", revision: "198d330bad8afecd585a6efd9776c91c9085bba5")
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
        ),
        .testTarget(
            name: "VoiceTypeTests",
            dependencies: ["VoiceType"]
        )
    ]
)
