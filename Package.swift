// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DellScan",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DellScan", path: "Sources/DellScan")
    ]
)
