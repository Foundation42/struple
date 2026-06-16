// swift-tools-version:6.0
import PackageDescription

// struple — streaming, lexicographically-ordered tuple packing.
//
// Pure, ZERO-dependency Swift. The `Struple` library is Foundation-free; the
// conformance/behavior runner (Tests/main.swift) uses Foundation only to read
// the shared JSON corpus.
//
// NOTE: on this host SwiftPM (`swift build`/`swift test`) is broken (missing
// libxml2.so.2). Build and verify with `./run-tests.sh`, which drives swiftc
// directly. This manifest is provided for real consumers with a working SwiftPM.
let package = Package(
    name: "Struple",
    products: [
        .library(name: "Struple", targets: ["Struple"])
    ],
    targets: [
        .target(name: "Struple", path: "Sources/Struple")
    ]
)
