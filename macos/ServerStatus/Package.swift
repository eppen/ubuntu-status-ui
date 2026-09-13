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
        .package(url: "https://github.com/eppen/Citadel.git", revision: "6b37d544f15d87c4eb71d7e2e3f446a5cca786e3")
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
