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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "TagLib",
            path: "Vendor/TagLib.xcframework"
        ),
        .binaryTarget(
            name: "Aubio",
            path: "Vendor/aubio.xcframework"
        ),
        .binaryTarget(
            name: "KeyFinder",
            path: "Vendor/KeyFinder.xcframework"
        ),
        .target(
            name: "SetifyCoreObjC",
            dependencies: ["TagLib", "Aubio", "KeyFinder"],
            path: "Sources/SetifyCoreObjC",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("TAGLIB_STATIC")
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "SetifyCore",
            dependencies: [
                "SetifyCoreObjC",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/SetifyCore"
        ),
        .testTarget(
            name: "SetifyCoreTests",
            dependencies: ["SetifyCore"],
            path: "Tests/SetifyCoreTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
