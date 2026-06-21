// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SimplePDF",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SimplePDF", targets: ["SimplePDF"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "SimplePDF",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/TheReader"
        )
    ]
)
