// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local log collector client; see ../logdock.
        .package(path: "../logdock/LogShip")
    ],
    targets: [
        .executableTarget(
            name: "DiskMap",
            dependencies: [.product(name: "LogShip", package: "LogShip")],
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
