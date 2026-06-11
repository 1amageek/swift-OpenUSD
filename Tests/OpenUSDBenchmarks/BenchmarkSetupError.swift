/// Errors raised while preparing benchmark inputs, before any measurement runs.
enum BenchmarkSetupError: Error, CustomStringConvertible {
    case missingFixture(String)

    var description: String {
        switch self {
        case .missingFixture(let path):
            return "Benchmark fixture not found at \(path); benchmarks must run from a source checkout."
        }
    }
}
