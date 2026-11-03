// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SubscriptionManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "subscription-manager", targets: ["SubscriptionManager"])
    ],
    targets: [
        .executableTarget(
            name: "SubscriptionManager",
            path: "Sources/SubscriptionManager"
        )
    ]
)
