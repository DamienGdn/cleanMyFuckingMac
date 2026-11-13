// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CleanMyFuckingMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CMFMCore"),
        .executableTarget(name: "CleanMyFuckingMac", dependencies: ["CMFMCore"]),
        .executableTarget(name: "cmfm-cli", dependencies: ["CMFMCore"]),
        .testTarget(name: "CMFMCoreTests", dependencies: ["CMFMCore"]),
    ]
)
