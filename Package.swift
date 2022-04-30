// swift-tools-version: 5.6

import PackageDescription

let package = Package(
    name: "CombinableSubprocess",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "CombinableSubprocess",
            targets: ["CombinableSubprocess"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CombinableSubprocess",
            dependencies: []),
        .testTarget(
            name: "CombinableSubprocessTests",
            dependencies: ["CombinableSubprocess"]),
    ]
)
