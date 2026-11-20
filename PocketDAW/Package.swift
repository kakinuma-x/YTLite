// swift-tools-version:5.9
// The audio core has no Apple-framework dependencies, so it can be unit-tested with `swift test`.
import PackageDescription

let package = Package(
    name: "DAWCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    targets: [
        .target(name: "DAWCore", path: "PocketDAW/Core"),
        .testTarget(name: "DAWCoreTests", dependencies: ["DAWCore"], path: "Tests/DAWCoreTests"),
    ]
)
