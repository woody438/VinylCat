// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VinylCat",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "VinylCat",
            path: "Sources/VinylCat",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
