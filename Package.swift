// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MDReader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MDReader",
            path: "Sources/MDReader",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
