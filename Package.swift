// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zennopay",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "Zennopay",
            targets: ["Zennopay"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Zennopay",
            dependencies: [],
            path: "Sources/Zennopay"
        ),
        .testTarget(
            name: "ZennopayTests",
            dependencies: ["Zennopay"],
            path: "Tests/ZennopayTests"
        )
    ]
)
