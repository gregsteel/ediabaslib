// swift-tools-version: 6.0
import PackageDescription

// UI + session logic as a plain library so it also builds with the macOS toolchain.
// The iOS app target lives in the Xcode project (see README.md) and links `DeepObdUI`.
let package = Package(
    name: "BmwDeepObdIos",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DeepObdUI", targets: ["DeepObdUI"]),
    ],
    dependencies: [
        .package(path: "../EdiabasKit"),
    ],
    targets: [
        .target(
            name: "DeepObdUI",
            dependencies: [.product(name: "EdiabasKit", package: "EdiabasKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
