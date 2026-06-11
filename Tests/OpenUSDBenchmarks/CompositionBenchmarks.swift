import Testing
import OpenUSD

extension Benchmarks {
    @Suite("Composition")
    struct Composition {

        @Test func flattenSublayerStack() throws {
            let stack = try SyntheticUSDASource.sublayerStack(
                sublayerCount: 10,
                primsPerSublayer: 200
            )
            let stage = USDStage(rootLayer: stack.rootLayer)
            let measurement = try BenchmarkMeasurement.measure(
                "USDStage.flattenedLayer 10 sublayers x 200 prims",
                iterations: 5
            ) {
                try stage.flattenedLayer(
                    resolvingWith: stack.provider,
                    rootIdentifier: "root.usda"
                ).specs.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }

        @Test func flattenReferenceForest() throws {
            let forest = try SyntheticUSDASource.referenceForest(referenceCount: 500)
            let stage = USDStage(rootLayer: forest.rootLayer)
            let measurement = try BenchmarkMeasurement.measure(
                "USDStage.flattenedLayer 500 reference arcs",
                iterations: 5
            ) {
                try stage.flattenedLayer(
                    resolvingWith: forest.provider,
                    rootIdentifier: "root.usda"
                ).specs.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }
    }
}
