// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DiskMap",
            path: "Sources/DiskMap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReclaimTests",
            dependencies: ["DiskMap"],
            path: "Tests/ReclaimTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
