// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PhoneMic",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "PhoneMicCore", targets: ["PhoneMicCore"]),
        .executable(name: "PhoneMicMac", targets: ["PhoneMicMac"]),
        .executable(name: "PhoneMicUSBProxyHelper", targets: ["PhoneMicUSBProxyHelper"]),
        .executable(name: "PhoneMicSelfTest", targets: ["PhoneMicSelfTest"])
    ],
    targets: [
        .target(name: "PhoneMicCore"),
        .executableTarget(
            name: "PhoneMicMac",
            dependencies: ["PhoneMicCore"]
        ),
        .executableTarget(
            name: "PhoneMicUSBProxyHelper",
            dependencies: ["PhoneMicCore"]
        ),
        .executableTarget(
            name: "PhoneMicSelfTest",
            dependencies: ["PhoneMicCore"]
        )
    ]
)
