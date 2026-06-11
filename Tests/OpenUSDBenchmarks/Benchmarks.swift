import Testing

/// Root suite for all OpenUSD performance benchmarks.
///
/// Benchmarks are opt-in only: every nested suite inherits the
/// `OPENUSD_BENCHMARKS=1` gate, so regular test runs and CI skip them.
/// `.serialized` is recursive, which keeps measurements from running
/// concurrently and disturbing each other.
///
/// Run locally with (release build for representative numbers):
///
///     OPENUSD_BENCHMARKS=1 swift test -c release --filter OpenUSDBenchmarks
@Suite(
    "OpenUSD Benchmarks",
    .tags(.benchmark),
    .serialized,
    .enabled(if: BenchmarkEnvironment.isEnabled),
    .timeLimit(.minutes(10))
)
enum Benchmarks {}
