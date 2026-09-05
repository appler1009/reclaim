// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Shared by the Mac app and the iOS companion: the wire types they
        // speak, and the few pieces of logic both draw with.
        .library(name: "ReclaimKit", targets: ["ReclaimKit"])
    ],
    targets: [
        .target(
            name: "ReclaimKit",
            path: "Sources/ReclaimKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DiskMap",
            dependencies: ["ReclaimKit"],
            path: "Sources/DiskMap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReclaimTests",
            dependencies: ["DiskMap", "ReclaimKit"],
            path: "Tests/ReclaimTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
