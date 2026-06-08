// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ResourceBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ResourceBar", targets: ["ResourceBar"])
    ],
    targets: [
        .executableTarget(
            name: "ResourceBar",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
