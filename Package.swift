// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ConcurrentDictionary",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .library(
            name: "ConcurrentDictionary",
            targets: ["ConcurrentDictionary"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swift-cloud/swift-xxh3", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "ConcurrentDictionary",
            dependencies: [
                .product(name: "XXH3", package: "swift-xxh3")
            ]
        ),
        .testTarget(
            name: "ConcurrentDictionaryTests",
            dependencies: ["ConcurrentDictionary"]
        ),
    ]
)
