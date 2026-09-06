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
        .package(url: "https://github.com/eppen/Citadel.git", revision: "5d0ad3a57696d091670aae65b64bcdea45206a65")
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
