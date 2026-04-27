// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Serv",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Serv", targets: ["Serv"]),
        .library(name: "ServCore", targets: ["ServCore"])
    ],
    targets: [
        .target(name: "ServCore"),
        .executableTarget(
            name: "Serv",
            dependencies: ["ServCore"]
        ),
        .testTarget(
            name: "ServCoreTests",
            dependencies: ["ServCore"]
        )
    ]
)
