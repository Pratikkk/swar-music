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
    targets: [
        .target(name: "Decoding"),
        .target(name: "AudioEngine", dependencies: ["Decoding"]),
        .target(name: "FormatInfo", dependencies: ["Decoding"]),
        .target(name: "Library", dependencies: ["Decoding"]),
        .target(name: "Player", dependencies: ["AudioEngine", "FormatInfo", "Library"]),
        .target(name: "SwarUI", dependencies: ["Player"])
    ],
    swiftLanguageModes: [.v6]
)
