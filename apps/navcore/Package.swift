// swift-tools-version: 6.0
// NavCore — the Swift port of engine/ (see docs/PORT.md). Pure logic,
// no Foundation, no Apple-only APIs: builds on Windows and Linux so the
// whole port can be developed and verified before any Mac exists.
import PackageDescription

let package = Package(
    name: "NavCore",
    products: [
        .library(name: "NavCore", targets: ["NavCore"])
    ],
    targets: [
        .target(name: "NavCore"),
        .testTarget(name: "NavCoreTests", dependencies: ["NavCore"]),
    ]
)
