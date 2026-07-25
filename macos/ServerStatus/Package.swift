// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ServerStatus",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ServerStatus", targets: ["ServerStatus"])
    ],
    dependencies: [
        .package(url: "https://github.com/eppen/Citadel.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "ServerStatus",
            dependencies: [
                .product(name: "Citadel", package: "Citadel")
            ],
            path: "Sources/ServerStatus"
        )
    ]
)
