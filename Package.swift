// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zennopay",
    platforms: [
        // Native SDK: iOS 16 is the floor for the SwiftUI checkout UI. The
        // presented flow uses .task, .tint, .overlay(alignment:), and the
        // .monospacedDigit() view modifier — all iOS 15/16+ — so the floor is
        // 16 (a v14 floor compiled only because the macOS 13 host has these
        // APIs; it fails to build for an iOS <16 target). Non-UI types (REST
        // client, state machine, JWT, idempotency) work further back, but the
        // presented flow requires 16.
        .iOS(.v16),
        // macOS is declared so `swift build` / `swift test` run on developer
        // and CI hosts. The SDK is iOS-only at runtime; the AVFoundation
        // scanner and UIKit presentation are compiled out on macOS. macOS 13
        // gives the SwiftUI screens the same API surface (.task, .tint) they
        // use on iOS 14 so the shared views compile on the host.
        .macOS(.v13)
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
            path: "Sources/Zennopay",
            // "Powered by Zennopay" footer logo (light + dark variants),
            // rendered at the bottom of every PaymentSheet screen.
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ZennopayTests",
            dependencies: ["Zennopay"],
            path: "Tests/ZennopayTests",
            // The cross-platform golden fixtures captured from the backend test
            // suite. Copied into the test bundle so the DTOs can be asserted to
            // decode the REAL request/response JSON verbatim.
            resources: [.copy("Fixtures")]
        )
    ]
)
