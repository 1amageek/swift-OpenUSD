import Testing
import OpenUSD

extension Benchmarks {
    @Suite("USDA Parsing")
    struct USDAParsing {

        @Test func parseFlatHierarchyWithOneThousandPrims() throws {
            let source = SyntheticUSDASource.flatXformHierarchy(primCount: 1_000)
            let measurement = try BenchmarkMeasurement.measure(
                "USDAReader.readLayer flat hierarchy, 1k prims",
                iterations: 5
            ) {
                try USDAReader().readLayer(from: source).specs.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }

        @Test func parseFlatHierarchyWithTenThousandPrims() throws {
            let source = SyntheticUSDASource.flatXformHierarchy(primCount: 10_000)
            let measurement = try BenchmarkMeasurement.measure(
                "USDAReader.readLayer flat hierarchy, 10k prims",
                iterations: 3
            ) {
                try USDAReader().readLayer(from: source).specs.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }

        @Test func materializeMeshSceneWithFiveHundredMeshes() throws {
            let source = SyntheticUSDASource.meshScene(meshCount: 500)
            let measurement = try BenchmarkMeasurement.measure(
                "USDAReader.read mesh scene, 500 meshes",
                iterations: 5
            ) {
                try USDAReader().read(from: source).meshes.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }
    }
}
