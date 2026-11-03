// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Teleprompter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Teleprompter",
            path: "Sources/Teleprompter"
        )
    ]
)
