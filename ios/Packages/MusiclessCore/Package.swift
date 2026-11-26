// swift-tools-version: 6.0
// Swift 6 language mode (complete strict concurrency). Builds for macOS too, so `swift test` runs on the Mac.
import Foundation
import PackageDescription

// ONNX Runtime comes from Microsoft's NuGet package, assembled locally by ios/tools/fetch_onnxruntime.sh
// (bootstrap.sh runs it; DECISIONS D27). It is gitignored, so fail with instructions, not a cryptic error.
let onnxRuntime = "Vendor/onnxruntime.xcframework"
if !FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + onnxRuntime) {
    fatalError("ONNX Runtime is missing from \(Context.packageDirectory)/\(onnxRuntime). Run ios/bootstrap.sh "
               + "(or ios/tools/fetch_onnxruntime.sh) once; it downloads Microsoft.ML.OnnxRuntime from nuget.org.")
}

let package = Package(
    name: "MusiclessCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MusiclessCore", targets: ["MusiclessCore"]),
    ],
    targets: [
        .binaryTarget(name: "onnxruntime", path: onnxRuntime),
        .target(
            name: "MusiclessCore",
            dependencies: ["onnxruntime"],
            // The iOS slices are a static C++ library: it needs libc++, zlib and sqlite3 (all in the OS),
            // Core ML for its execution provider, and UIKit (it reads UIDevice).
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z"), .linkedLibrary("sqlite3"),
                             .linkedFramework("CoreML"), .linkedFramework("UIKit", .when(platforms: [.iOS]))]
        ),
        .testTarget(
            name: "MusiclessCoreTests",
            dependencies: ["MusiclessCore"],
            // Fixtures/dsp: golden output of Android's MusiclessDsp.java (ios/tools/dsp-golden/run.sh).
            resources: [.copy("Fixtures")]
        ),
    ]
)
