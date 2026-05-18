// swift-tools-version: 6.2
//
// xAISTTKit — xAI Grok Speech-to-Text client for Apple platforms.
//
// Mirrors the API surface of xAITTSKit so it plugs into the OpenClaw iOS Talk
// Mode pipeline (alongside Apple Speech and Parakeet STT providers) without
// further abstraction.
//

import PackageDescription

let package = Package(
    name: "xAISTTKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "xAISTTKit", targets: ["xAISTTKit"])
    ],
    targets: [
        .target(name: "xAISTTKit", path: "Sources/xAISTTKit"),
        .testTarget(name: "xAISTTKitTests", dependencies: ["xAISTTKit"], path: "Tests/xAISTTKitTests")
    ],
    swiftLanguageModes: [.v6]
)
