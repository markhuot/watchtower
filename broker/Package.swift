// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WatchtowerBroker",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "watchtower-broker", targets: ["watchtower-broker"]),
        .executable(name: "watchtower-broker-cli", targets: ["watchtower-broker-cli"]),
        .library(name: "WatchtowerBrokerCore", targets: ["WatchtowerBrokerCore"]),
    ],
    targets: [
        .target(
            name: "WatchtowerBrokerCore",
            path: "Sources/WatchtowerBrokerCore"
        ),
        .executableTarget(
            name: "watchtower-broker",
            dependencies: ["WatchtowerBrokerCore"],
            path: "Sources/watchtower-broker"
        ),
        .executableTarget(
            name: "watchtower-broker-cli",
            dependencies: ["WatchtowerBrokerCore"],
            path: "Sources/watchtower-broker-cli"
        ),
        .testTarget(
            name: "WatchtowerBrokerCoreTests",
            dependencies: ["WatchtowerBrokerCore"],
            path: "Tests/WatchtowerBrokerCoreTests"
        ),
    ]
)
