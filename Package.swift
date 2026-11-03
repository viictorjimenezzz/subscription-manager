// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuotaManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "quota-manager", targets: ["QuotaManager"])
    ],
    targets: [
        .executableTarget(
            name: "QuotaManager",
            path: "Sources/QuotaManager"
        )
    ]
)
