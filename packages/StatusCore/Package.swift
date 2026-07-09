// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StatusCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "StatusCore", targets: ["StatusCore"])
    ],
    targets: [
        .target(name: "StatusCore"),
        .testTarget(
            name: "StatusCoreTests",
            dependencies: ["StatusCore"]
        )
    ]
)
