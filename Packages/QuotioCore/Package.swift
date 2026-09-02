// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuotioCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "QuotioDomain", targets: ["QuotioDomain"]),
        .library(name: "QuotioApplication", targets: ["QuotioApplication"]),
        .library(name: "QuotioInfrastructure", targets: ["QuotioInfrastructure"]),
        .library(name: "QuotioPresentation", targets: ["QuotioPresentation"]),
    ],
    targets: [
        .target(name: "QuotioDomain"),
        .target(
            name: "QuotioApplication",
            dependencies: ["QuotioDomain"]
        ),
        .target(
            name: "QuotioInfrastructure",
            dependencies: ["QuotioApplication", "QuotioDomain"]
        ),
        .target(
            name: "QuotioPresentation",
            dependencies: ["QuotioApplication", "QuotioDomain"]
        ),
        .testTarget(
            name: "QuotioDomainTests",
            dependencies: ["QuotioDomain"]
        ),
        .testTarget(
            name: "QuotioApplicationTests",
            dependencies: ["QuotioApplication", "QuotioDomain"]
        ),
        .testTarget(
            name: "QuotioInfrastructureTests",
            dependencies: ["QuotioInfrastructure", "QuotioApplication", "QuotioDomain"]
        ),
        .testTarget(
            name: "QuotioPresentationTests",
            dependencies: ["QuotioPresentation", "QuotioApplication", "QuotioDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
