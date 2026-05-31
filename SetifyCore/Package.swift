// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SetifyCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SetifyCore", targets: ["SetifyCore"])
    ],
    targets: [
        .target(
            name: "SetifyCore",
            path: "Sources/SetifyCore"
        )
    ]
)
