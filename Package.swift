// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyCast",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AnyCast",
            path: "Sources/AnyCast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
