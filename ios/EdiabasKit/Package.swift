// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdiabasKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EdiabasKit", targets: ["EdiabasKit"]),
    ],
    targets: [
        .target(
            name: "EdiabasKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EdiabasCheck",
            dependencies: ["EdiabasKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdiabasKitTests",
            dependencies: ["EdiabasKit"],
            exclude: ["Golden", "opnames.txt"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
