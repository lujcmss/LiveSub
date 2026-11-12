// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveSub",
    platforms: [.macOS("26.4")],
    products: [
        .executable(name: "livesub", targets: ["livesub"]),
    ],
    targets: [
        .target(
            name: "LiveSubCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "livesub",
            dependencies: ["LiveSubCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LiveSubCoreTests",
            dependencies: ["LiveSubCore"],
            // With only the Command Line Tools installed (no Xcode), the Swift Testing macro
            // plugin is not always on the compiler's search path; point at it explicitly.
            swiftSettings: [.unsafeFlags([
                "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
            ])]
        ),
    ]
)
