// swift-tools-version: 6.0
import PackageDescription

// Mac command line tool: pretends to be a BLE ELM327 adapter with a simulated BMW ECU behind it.
let package = Package(
    name: "ElmBleSim",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../EdiabasKit")],
    targets: [
        .executableTarget(
            name: "ElmBleSim",
            dependencies: [.product(name: "EdiabasKit", package: "EdiabasKit")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Bluetooth needs a usage description even for command line tools
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/ElmBleSim/Info.plist"]),
            ]
        ),
    ]
)
