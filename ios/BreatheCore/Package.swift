// swift-tools-version: 6.0
import PackageDescription

// Everything about the pacer that is not UI or audio I/O: the clock, the tick
// waveform, the sample-accurate tick scheduler and the orb's geometry. Kept
// free of Apple-only frameworks so it builds and tests on Linux too.
let package = Package(
    name: "BreatheCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BreatheCore", targets: ["BreatheCore"]),
    ],
    targets: [
        .target(name: "BreatheCore"),
        .testTarget(name: "BreatheCoreTests", dependencies: ["BreatheCore"]),
    ]
)
