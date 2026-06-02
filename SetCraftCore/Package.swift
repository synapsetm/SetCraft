// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SetCraftCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SetCraftCore", targets: ["SetCraftCore"])
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
            name: "SetCraftCoreObjC",
            dependencies: ["TagLib", "Aubio", "KeyFinder"],
            path: "Sources/SetCraftCoreObjC",
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
            name: "SetCraftCore",
            dependencies: [
                "SetCraftCoreObjC",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/SetCraftCore"
        ),
        .testTarget(
            name: "SetCraftCoreTests",
            dependencies: ["SetCraftCore"],
            path: "Tests/SetCraftCoreTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
