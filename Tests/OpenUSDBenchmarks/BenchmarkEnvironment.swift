import Foundation

/// Gates benchmark execution behind an explicit opt-in and resolves shared
/// fixture data. Regular test runs and CI never set the gate variable, so the
/// measurement suites are always skipped there.
enum BenchmarkEnvironment {
    /// Environment variable that enables benchmark execution when set to "1".
    static let enableVariable = "OPENUSD_BENCHMARKS"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[enableVariable] == "1"
    }

    /// Loads a generated crate fixture from the sibling `OpenUSDTests` target.
    ///
    /// Benchmarks are local-only by design, so the repository layout is
    /// resolved relative to this source file instead of bundling duplicate
    /// fixture resources into a second test target.
    static func generatedFixtureData(named name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenUSDTests/Fixtures/Generated/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkSetupError.missingFixture(url.path)
        }
        return try Data(contentsOf: url)
    }
}
