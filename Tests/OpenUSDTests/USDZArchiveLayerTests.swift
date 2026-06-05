import Foundation
import Testing
import OpenUSD
import OpenUSDZ

@Suite("USDZ Archive Layers")
struct USDZArchiveLayerTests {
    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFZipFileReaderFixtureReadsEntryInfoAndData() throws {
        let archive = try openSDFZipFixtureArchive("test_reader.usdz")

        #expect(archive.centralDirectoryOffset == 13_783)
        #expect(archive.centralDirectorySize == 310)
        #expect(archive.endOfCentralDirectoryOffset == 14_093)
        #expect(archive.entryPaths == ["a.test", "b.png", "sub/c.png", "sub/d.txt"])
        #expect(archive.entryData(at: "nonexistent.txt") == nil)
        #expect(archive.entry(at: "nonexistent.txt") == nil)

        let cases: [SDFZipEntryCase] = [
            SDFZipEntryCase(path: "a.test", dataOffset: 64, size: 83, crc32: 2_187_659_876, normalizesLineEndings: true),
            SDFZipEntryCase(path: "b.png", dataOffset: 192, size: 7_228, crc32: 384_784_137),
            SDFZipEntryCase(path: "sub/c.png", dataOffset: 7_488, size: 6_139, crc32: 2_488_450_460),
            SDFZipEntryCase(path: "sub/d.txt", dataOffset: 13_696, size: 87, crc32: 2_546_026_356, normalizesLineEndings: true),
        ]

        for testCase in cases {
            let entry = try #require(archive.entry(at: testCase.path))
            #expect(entry.dataOffset == testCase.dataOffset)
            #expect(entry.size == testCase.size)
            #expect(entry.uncompressedSize == testCase.size)
            #expect(entry.crc32 == testCase.crc32)
            #expect(entry.compressionMethod == 0)
            #expect(!entry.isEncrypted)
            #expect(entry.isPayload64ByteAligned)

            let zippedData = try #require(archive.entryData(at: testCase.path))
            var sourceData = try openSDFZipFixture("src/\(testCase.path)")
            if testCase.normalizesLineEndings {
                sourceData = sourceData.normalizingCRLFLineEndings()
            }
            #expect(zippedData == sourceData)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSingleUSDZFixturesResolveDefaultLayerData() throws {
        let cases = [
            (archive: "single_usd.usdz", layer: "test.usd", source: "single/test.usd"),
            (archive: "single_usda.usdz", layer: "test.usda", source: "single/test.usda"),
            (archive: "single_usdc.usdz", layer: "test.usdc", source: "single/test.usdc"),
        ]

        for testCase in cases {
            let archive = try openUSDZArchive(testCase.archive)

            #expect(archive.defaultLayer?.path == testCase.layer)
            #expect(try archive.data(for: testCase.layer) == openUSDZFixture(testCase.source))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDAnchoredReferencesUSDZResolvesContainedLayers() throws {
        let archive = try openUSDZArchive("anchored_refs.usdz")

        #expect(archive.entries.map(\.path) == ["root.usd", "ref.usd", "sub/ref.usdc", "sub/ref.usda"])
        #expect(try archive.data(for: "root.usd") == openUSDZFixture("anchored_refs/root.usd"))
        #expect(try archive.data(for: "ref.usd") == openUSDZFixture("anchored_refs/ref.usd"))
        #expect(try archive.data(for: "sub/ref.usdc") == openUSDZFixture("anchored_refs/sub/ref.usdc"))
        #expect(try archive.data(for: "sub/ref.usda") == openUSDZFixture("anchored_refs/sub/ref.usda"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDNestedReferencesUSDZResolvesNestedContainedLayers() throws {
        let archive = try openUSDZArchive("nested_anchored_refs.usdz")

        #expect(archive.entries.map(\.path) == ["anchored_refs.usdz"])
        #expect(
            try archive.data(for: "anchored_refs.usdz[root.usd]")
                == openUSDZFixture("anchored_refs/root.usd")
        )
        #expect(
            try archive.data(for: "anchored_refs.usdz[sub/ref.usdc]")
                == openUSDZFixture("anchored_refs/sub/ref.usdc")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDAnchoredReferencesUSDZResolvesAuthoredAssetPaths() throws {
        let archive = try openUSDZArchive("anchored_refs_sub.usdz")

        #expect(
            try archive.resolveLayerPath(for: "./ref.usd", referencedFrom: "anchored_refs/root.usd")
                == "anchored_refs/ref.usd"
        )
        #expect(
            try archive.data(for: "./ref.usd", referencedFrom: "anchored_refs/root.usd")
                == openUSDZFixture("anchored_refs/ref.usd")
        )
        #expect(
            try archive.resolveLayerPath(for: "./sub/ref.usda", referencedFrom: "anchored_refs/ref.usd")
                == "anchored_refs/sub/ref.usda"
        )
        #expect(
            try archive.resolveLayerPath(for: "./sub/ref.usdc", referencedFrom: "anchored_refs/ref.usd")
                == "anchored_refs/sub/ref.usdc"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSearchReferencesUSDZUsesSourceDirectoryBeforeDefaultLayerDirectory() throws {
        let archive = try openUSDZArchive("search_refs.usdz")

        #expect(
            try archive.resolveLayerPath(for: "sub/ref_in_subdir.usd", referencedFrom: "refs/ref.usd")
                == "refs/sub/ref_in_subdir.usd"
        )
        #expect(
            try archive.resolveLayerPath(for: "sub/ref_in_root.usd", referencedFrom: "refs/ref.usd")
                == "sub/ref_in_root.usd"
        )
        #expect(
            try archive.resolveLayerPath(for: "sub/ref_in_both.usd", referencedFrom: "refs/ref.usd")
                == "refs/sub/ref_in_both.usd"
        )
        #expect(
            try archive.data(for: "sub/ref_in_both.usd", referencedFrom: "refs/ref.usd")
                == openUSDZFixture("search_refs/refs/sub/ref_in_both.usd")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSearchReferencesUSDZUsesDefaultLayerDirectoryAsPackageRoot() throws {
        let archive = try openUSDZArchive("search_refs_sub.usdz")

        #expect(
            try archive.resolveLayerPath(for: "./refs/ref.usd", referencedFrom: "search_refs/root.usd")
                == "search_refs/refs/ref.usd"
        )
        #expect(
            try archive.resolveLayerPath(for: "sub/ref_in_root.usd", referencedFrom: "search_refs/refs/ref.usd")
                == "search_refs/sub/ref_in_root.usd"
        )
        #expect(
            try archive.resolveLayerPath(for: "sub/ref_in_both.usd", referencedFrom: "search_refs/refs/ref.usd")
                == "search_refs/refs/sub/ref_in_both.usd"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDNestedReferencesUSDZComposesResolvedLayerPaths() throws {
        let anchoredArchive = try openUSDZArchive("nested_anchored_refs_sub.usdz")
        let searchArchive = try openUSDZArchive("nested_search_refs.usdz")

        #expect(
            try anchoredArchive.resolveLayerPath(
                for: "./ref.usd",
                referencedFrom: "anchored_refs_sub.usdz[anchored_refs/root.usd]"
            )
                == "anchored_refs_sub.usdz[anchored_refs/ref.usd]"
        )
        #expect(
            try anchoredArchive.data(
                for: "./sub/ref.usda",
                referencedFrom: "anchored_refs_sub.usdz[anchored_refs/ref.usd]"
            )
                == openUSDZFixture("anchored_refs/sub/ref.usda")
        )
        #expect(
            try searchArchive.resolveLayerPath(
                for: "sub/ref_in_both.usd",
                referencedFrom: "search_refs.usdz[refs/ref.usd]"
            )
                == "search_refs.usdz[refs/sub/ref_in_both.usd]"
        )
        #expect(
            try searchArchive.data(
                for: "sub/ref_in_root.usd",
                referencedFrom: "search_refs.usdz[refs/ref.usd]"
            )
                == openUSDZFixture("search_refs/sub/ref_in_root.usd")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func containedLayerResolutionReportsTypedUSDZErrors() throws {
        let archive = try openUSDZArchive("anchored_refs.usdz")

        #expect(throws: USDImportError.self) {
            _ = try archive.data(for: "missing.usd")
        }
        #expect(throws: USDImportError.self) {
            _ = try archive.data(for: "root.usd[child.usd]")
        }
        #expect(throws: USDImportError.self) {
            _ = try archive.data(for: "root.usd[child.usd")
        }
        #expect(try archive.resolveLayerPath(for: "./missing.usd", referencedFrom: "root.usd") == nil)
        #expect(throws: USDImportError.self) {
            _ = try archive.data(for: "./missing.usd", referencedFrom: "root.usd")
        }
    }
}

private func openUSDZArchive(_ relativePath: String) throws -> USDZArchive {
    try USDZArchive(data: openUSDZFixture(relativePath))
}

private func openSDFZipFixtureArchive(_ relativePath: String) throws -> USDZArchive {
    try USDZArchive(data: openSDFZipFixture(relativePath))
}

private func openUSDZFixture(_ relativePath: String) throws -> Data {
    try openFixture(root: "testUsdUsdzFileFormat", relativePath: relativePath)
}

private func openSDFZipFixture(_ relativePath: String) throws -> Data {
    try openFixture(root: "testSdfZipFile.testenv", relativePath: relativePath)
}

private func openFixture(root: String, relativePath: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("OpenUSD")
        .appendingPathComponent(root)
        .appendingPathComponent(relativePath)
    return try Data(contentsOf: url)
}

private struct SDFZipEntryCase {
    var path: String
    var dataOffset: Int
    var size: Int
    var crc32: UInt32
    var normalizesLineEndings: Bool = false
}

private extension Data {
    func normalizingCRLFLineEndings() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
    }
}
