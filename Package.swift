// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JellyfinMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JellyfinMac",
            path: "Sources/JellyfinMac"
        )
    ]
)
