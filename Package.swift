// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyCast",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "VirtualDisplayKit",
            path: "Sources/VirtualDisplayKit",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .executableTarget(
            name: "AnyCast",
            dependencies: ["VirtualDisplayKit"],
            path: "Sources/AnyCast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
