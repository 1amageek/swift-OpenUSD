import Foundation

/// Wall-clock measurement for a single benchmark case.
///
/// Each measured iteration returns an `Int` that is folded into `checksum`;
/// consuming the body's result keeps the optimizer from eliminating the
/// measured work and lets tests assert that the work actually happened.
struct BenchmarkMeasurement {
    let name: String
    let iterations: Int
    let minimum: Duration
    let median: Duration
    let mean: Duration
    let checksum: Int

    static func measure(
        _ name: String,
        warmupIterations: Int = 1,
        iterations: Int,
        _ body: () throws -> Int
    ) rethrows -> BenchmarkMeasurement {
        precondition(iterations >= 1, "Benchmarks need at least one measured iteration.")
        var checksum = 0
        for _ in 0..<warmupIterations {
            checksum &+= try body()
        }
        let clock = ContinuousClock()
        var durations: [Duration] = []
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = clock.now
            checksum &+= try body()
            durations.append(clock.now - start)
        }
        let sorted = durations.sorted()
        let total = durations.reduce(Duration.zero, +)
        return BenchmarkMeasurement(
            name: name,
            iterations: iterations,
            minimum: sorted[0],
            median: sorted[sorted.count / 2],
            mean: total / iterations,
            checksum: checksum
        )
    }

    /// Prints one summary line; benchmark output is read from the test log.
    func report() {
        print(
            "[benchmark] \(name): "
                + "min=\(Self.millisecondsText(minimum))ms "
                + "median=\(Self.millisecondsText(median))ms "
                + "mean=\(Self.millisecondsText(mean))ms "
                + "iterations=\(iterations)"
        )
    }

    private static func millisecondsText(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.3f", milliseconds)
    }
}
