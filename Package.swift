// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WristAssist",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "WristAssistShared",
            targets: ["WristAssistShared"]
        ),
        .executable(
            name: "WristAssistSharedSmokeTests",
            targets: ["WristAssistSharedSmokeTests"]
        )
    ],
    targets: [
        .target(
            name: "WristAssistShared",
            path: "Sources/WristAssistShared"
        ),
        .testTarget(
            name: "WristAssistSharedTests",
            dependencies: ["WristAssistShared"],
            path: "Tests/WristAssistSharedTests"
        ),
        .executableTarget(
            name: "WristAssistSharedSmokeTests",
            dependencies: ["WristAssistShared"],
            path: "Tools/WristAssistSharedSmokeTests"
        )
    ]
)
