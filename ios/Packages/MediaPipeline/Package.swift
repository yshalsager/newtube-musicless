// swift-tools-version: 6.0
// Swift 6 language mode (complete strict concurrency). Builds for macOS too, so `swift test` runs on the Mac.
import PackageDescription

let package = Package(
    name: "MediaPipeline",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MediaPipeline", targets: ["MediaPipeline"]),
    ],
    targets: [
        .target(name: "MediaPipeline"),
        .testTarget(
            name: "MediaPipelineTests",
            dependencies: ["MediaPipeline"],
            // Fixtures/media: Big Buck Bunny byte ranges (CC BY 3.0), see Fixtures/media/LICENSE.md.
            resources: [.copy("Fixtures")]
        ),
    ]
)
