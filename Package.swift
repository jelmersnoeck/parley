// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Parley",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Parley",
            path: "Sources/Parley",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "ParleyTests",
            dependencies: ["Parley"],
            path: "Tests/ParleyTests"
        )
    ]
)
