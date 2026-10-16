// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "Decoding", targets: ["Decoding"]),
        .library(name: "FormatInfo", targets: ["FormatInfo"]),
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Player", targets: ["Player"]),
        .library(name: "SwarUI", targets: ["SwarUI"])
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "FFmpegBridge", cSettings: [.headerSearchPath("../../Vendor/FFmpeg/include")]),
        .target(name: "Decoding", dependencies: ["FFmpegBridge"]),
        .target(name: "RealtimeAudio"),
        .target(name: "AudioEngine", dependencies: ["Decoding", "RealtimeAudio"]),
        .target(name: "FormatInfo", dependencies: ["Decoding"]),
        .target(name: "Library", dependencies: ["Decoding", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Player", dependencies: ["AudioEngine", "FormatInfo", "Library"]),
        .target(name: "SwarUI", dependencies: ["Player", "FormatInfo", "Decoding", "Library"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Decoding"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FormatInfoTests", dependencies: ["FormatInfo", "Decoding"]),
        .testTarget(name: "DecodingTests", dependencies: ["Decoding"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RealtimeAudioTests", dependencies: ["RealtimeAudio"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "Decoding"]),
        .testTarget(name: "PlayerTests", dependencies: ["Player"])
    ],
    swiftLanguageModes: [.v6]
)
