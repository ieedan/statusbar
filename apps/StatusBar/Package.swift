// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StatusBar",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../../packages/StatusCore")
    ],
    targets: [
        .executableTarget(
            name: "StatusBar",
            dependencies: [
                .product(name: "StatusCore", package: "StatusCore")
            ]
        )
    ]
)
