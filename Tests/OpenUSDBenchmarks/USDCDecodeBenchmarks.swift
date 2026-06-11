import Foundation
import Testing
import OpenUSD
import OpenUSDC

extension Benchmarks {
    @Suite("USDC Decode")
    struct USDCDecode {

        private static let fixtureNames = [
            "minimal_mesh.usdc",
            "animated_mesh.usdc",
            "combined_rotation_mesh.usdc",
            "display_color_mesh.usdc",
            "extent_mesh.usdc",
            "uv_mesh.usdc",
        ]

        @Test func decodeGeneratedCrateLayers() throws {
            let fixtures = try Self.fixtureNames.map {
                try BenchmarkEnvironment.generatedFixtureData(named: $0)
            }
            let measurement = try BenchmarkMeasurement.measure(
                "USDCReader.readLayer 6 fixtures x 50 reads",
                iterations: 5
            ) {
                var specCount = 0
                for fixture in fixtures {
                    for _ in 0..<50 {
                        specCount += try USDCReader().readLayer(from: fixture).specs.count
                    }
                }
                return specCount
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }

        @Test func materializeGeneratedCrateScenes() throws {
            let fixtures = try Self.fixtureNames.map {
                try BenchmarkEnvironment.generatedFixtureData(named: $0)
            }
            let measurement = try BenchmarkMeasurement.measure(
                "USDCReader.read 6 fixtures x 50 reads",
                iterations: 5
            ) {
                var meshCount = 0
                for fixture in fixtures {
                    for _ in 0..<50 {
                        meshCount += try USDCReader().read(from: fixture).meshes.count
                    }
                }
                return meshCount
            }
            measurement.report()
            #expect(measurement.checksum > 0)
        }
    }
}
