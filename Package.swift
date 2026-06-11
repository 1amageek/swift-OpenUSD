// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "swift-OpenUSD",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
        .custom("wasi", versionString: "0")
    ],
    products: [
        .library(
            name: "OpenUSD",
            targets: ["OpenUSD"]
        ),
        .library(
            name: "OpenUSDC",
            targets: ["OpenUSDC"]
        ),
        .library(
            name: "OpenUSDZ",
            targets: ["OpenUSDZ"]
        ),
    ],
    targets: [
        .target(
            name: "OpenUSD"
        ),
        .target(
            name: "OpenUSDC",
            dependencies: ["OpenUSD"]
        ),
        .target(
            name: "OpenUSDZ",
            dependencies: ["OpenUSD", "OpenUSDC"]
        ),
        .testTarget(
            name: "OpenUSDTests",
            dependencies: ["OpenUSD", "OpenUSDC", "OpenUSDZ"],
            exclude: ["UPSTREAM_TEST_PARITY.md", "UNSUPPORTED_FEATURES.json"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        // Performance benchmarks. Gated behind OPENUSD_BENCHMARKS=1 so normal
        // test runs and CI skip them; run locally with:
        //   OPENUSD_BENCHMARKS=1 swift test -c release --filter OpenUSDBenchmarks
        .testTarget(
            name: "OpenUSDBenchmarks",
            dependencies: ["OpenUSD", "OpenUSDC", "OpenUSDZ"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
