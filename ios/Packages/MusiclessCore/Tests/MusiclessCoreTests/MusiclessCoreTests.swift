import MusiclessCore
import Testing

// Plain imports (no @testable) in this target, so `swift test -c release` can run the benchmark.

@Test func moduleIsLinked() {
    #expect(MusiclessCoreModule.name == "MusiclessCore")
}

/// Where the tests run, for printed measurements.
enum TestPlatform {
    static var name: String {
        #if targetEnvironment(simulator)
        "iOS simulator"
        #elseif os(iOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }
}
