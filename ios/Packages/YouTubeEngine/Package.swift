// swift-tools-version: 6.0
// Swift 6 language mode (complete strict concurrency). Builds for macOS too, so `swift test` runs on the Mac.
import PackageDescription

let package = Package(
    name: "YouTubeEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "YouTubeEngine", targets: ["YouTubeEngine"]),
    ],
    targets: [
        .target(
            name: "YouTubeEngine",
            // JS/nsigsolver: yt-dlp's EJS challenge solver and its parser libraries (US-016).
            resources: [.copy("JS")],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "YouTubeEngineTests",
            dependencies: ["YouTubeEngine"],
            // Fixtures/answers: /player answers recorded on the iPhone by `--record-answers`,
            // scrubbed by AnswerScrubber (no visitor ids, the requester's IP replaced).
            resources: [.copy("Fixtures")]
        ),
    ]
)
