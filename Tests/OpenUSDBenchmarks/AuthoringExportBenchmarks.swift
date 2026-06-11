import Testing
import OpenUSD

extension Benchmarks {
    @Suite("Authoring and Export")
    struct AuthoringExport {

        @Test func authorTwoThousandPrims() throws {
            let measurement = try BenchmarkMeasurement.measure(
                "USDStage.definePrim 2k prims",
                iterations: 3
            ) {
                var stage = USDStage.createInMemory(defaultPrim: "Root")
                for index in 0..<2_000 {
                    try stage.definePrim(at: SdfPath("/Root/Prim\(index)"), typeName: "Xform")
                }
                return stage.rootLayer.specs.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }

        @Test func exportLayerWithTenThousandPrims() throws {
            let source = SyntheticUSDASource.flatXformHierarchy(primCount: 10_000)
            let layer = try USDAReader().readLayer(from: source)
            let measurement = try BenchmarkMeasurement.measure(
                "USDAWriter.string 10k prims",
                iterations: 3
            ) {
                try USDAWriter().string(for: layer).utf8.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }

        @Test func sdfLayerRoundTripWithOneThousandPrims() throws {
            let source = SyntheticUSDASource.flatXformHierarchy(primCount: 1_000)
            let measurement = try BenchmarkMeasurement.measure(
                "SdfLayer.importUSDA + exportUSDA 1k prims",
                iterations: 5
            ) {
                try SdfLayer.importUSDA(from: source).exportUSDA().utf8.count
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }
    }
}
