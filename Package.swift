// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JunkFinder",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "JunkCore"),
        .executableTarget(name: "junk", dependencies: ["JunkCore"]),
        .testTarget(name: "JunkCoreTests", dependencies: ["JunkCore"]),
    ]
)
