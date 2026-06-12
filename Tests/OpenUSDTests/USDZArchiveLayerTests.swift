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
    func openUSDSDFUSDZResolverFixtureReadsEntriesAndNestedData() throws {
        let packageData = try openSDFUSDZResolverFixture("test.usdz")
        let archive = try USDZArchive(data: packageData)
        #expect(archive.entry(at: "bogus.file") == nil)
        #expect(throws: USDError.self) {
            _ = try archive.assetData(at: "bogus.file")
        }
        #expect(archive.entryPaths == ["file_1.usdc", "nested.usdz", "file_2.usdc", "subdir/file_3.usdc"])

        let topLevelCases: [SDFZipEntryCase] = [
            SDFZipEntryCase(path: "file_1.usdc", dataOffset: 64, size: 680),
            SDFZipEntryCase(path: "nested.usdz", dataOffset: 832, size: 2_376),
            SDFZipEntryCase(path: "file_2.usdc", dataOffset: 3_264, size: 621),
            SDFZipEntryCase(path: "subdir/file_3.usdc", dataOffset: 3_968, size: 640),
        ]

        for testCase in topLevelCases {
            try assertSDFUSDZResolverEntry(
                testCase,
                in: archive,
                packageData: packageData,
                sourcePath: "src/\(testCase.path)"
            )
        }

        #expect(try archive.assetData(at: "nested.usdz") == openSDFUSDZResolverFixture("src/nested.usdz"))
        #expect(try archive.layerData(at: "file_1.usdc") == openSDFUSDZResolverFixture("src/file_1.usdc"))
        #expect(try archive.layerData(at: "file_2.usdc") == openSDFUSDZResolverFixture("src/file_2.usdc"))
        #expect(
            try archive.layerData(at: "subdir/file_3.usdc")
                == openSDFUSDZResolverFixture("src/subdir/file_3.usdc")
        )
        #expect(try archive.layerData(at: "nested.usdz[file_1.usdc]") == openSDFUSDZResolverFixture("src/file_1.usdc"))
        #expect(try archive.layerData(at: "nested.usdz[file_2.usdc]") == openSDFUSDZResolverFixture("src/file_2.usdc"))
        #expect(
            try archive.layerData(at: "nested.usdz[subdir/file_3.usdc]")
                == openSDFUSDZResolverFixture("src/subdir/file_3.usdc")
        )

        let nestedEntry = try #require(archive.entry(at: "nested.usdz"))
        let nestedArchive = try USDZArchive(data: nestedEntry.data)
        let nestedCases: [SDFZipEntryCase] = [
            SDFZipEntryCase(path: "file_1.usdc", dataOffset: 896, size: 680),
            SDFZipEntryCase(path: "file_2.usdc", dataOffset: 1_664, size: 621),
            SDFZipEntryCase(path: "subdir/file_3.usdc", dataOffset: 2_368, size: 640),
        ]

        for testCase in nestedCases {
            let entry = try #require(nestedArchive.entry(at: testCase.path))
            let sourceData = try openSDFUSDZResolverFixture("src/\(testCase.path)")
            let nestedPath = "nested.usdz[\(testCase.path)]"
            #expect(nestedEntry.dataOffset + entry.dataOffset == testCase.dataOffset)
            #expect(entry.size == testCase.size)
            #expect(entry.uncompressedSize == testCase.size)
            #expect(entry.compressionMethod == 0)
            #expect(!entry.isEncrypted)
            #expect(entry.isPayload64ByteAligned)
            #expect(entry.data == sourceData)
            #expect(entry.data.dropFirst(100).elementsEqual(sourceData.dropFirst(100)))
            try assertDataSlice(packageData, offset: testCase.dataOffset, equals: sourceData)
            #expect(try archive.assetData(at: nestedPath) == sourceData)
            #expect(try archive.layerData(at: nestedPath) == sourceData)
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
            #expect(try archive.layerData(at: testCase.layer) == openUSDZFixture(testCase.source))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDAnchoredReferencesUSDZResolvesContainedLayers() throws {
        let archive = try openUSDZArchive("anchored_refs.usdz")

        #expect(archive.entries.map(\.path) == ["root.usd", "ref.usd", "sub/ref.usdc", "sub/ref.usda"])
        #expect(try archive.layerData(at: "root.usd") == openUSDZFixture("anchored_refs/root.usd"))
        #expect(try archive.layerData(at: "ref.usd") == openUSDZFixture("anchored_refs/ref.usd"))
        #expect(try archive.layerData(at: "sub/ref.usdc") == openUSDZFixture("anchored_refs/sub/ref.usdc"))
        #expect(try archive.layerData(at: "sub/ref.usda") == openUSDZFixture("anchored_refs/sub/ref.usda"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDNestedReferencesUSDZResolvesNestedContainedLayers() throws {
        let archive = try openUSDZArchive("nested_anchored_refs.usdz")

        #expect(archive.entries.map(\.path) == ["anchored_refs.usdz"])
        #expect(
            try archive.layerData(at: "anchored_refs.usdz[root.usd]")
                == openUSDZFixture("anchored_refs/root.usd")
        )
        #expect(
            try archive.layerData(at: "anchored_refs.usdz[sub/ref.usdc]")
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
            try archive.layerData(for: "./ref.usd", referencedFrom: "anchored_refs/root.usd")
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
            try archive.layerData(for: "sub/ref_in_both.usd", referencedFrom: "refs/ref.usd")
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
            try anchoredArchive.layerData(
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
            try searchArchive.layerData(
                for: "sub/ref_in_root.usd",
                referencedFrom: "search_refs.usdz[refs/ref.usd]"
            )
                == openUSDZFixture("search_refs/sub/ref_in_root.usd")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func containedLayerResolutionReportsTypedUSDZErrors() throws {
        let archive = try openUSDZArchive("anchored_refs.usdz")

        #expect(throws: USDError.self) {
            _ = try archive.layerData(at: "missing.usd")
        }
        #expect(throws: USDError.self) {
            _ = try archive.layerData(at: "root.usd[child.usd]")
        }
        #expect(throws: USDError.self) {
            _ = try archive.layerData(at: "root.usd[child.usd")
        }
        #expect(try archive.resolveLayerPath(for: "./missing.usd", referencedFrom: "root.usd") == nil)
        #expect(throws: USDError.self) {
            _ = try archive.layerData(for: "./missing.usd", referencedFrom: "root.usd")
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

private func openSDFUSDZResolverFixture(_ relativePath: String) throws -> Data {
    try openFixture(root: "testSdfUsdzResolver", relativePath: relativePath)
}

private func openFixture(root: String, relativePath: String) throws -> Data {
    #if SWIFT_PACKAGE
    if let resourceURL = Bundle.module.resourceURL {
        let fixtureURL = resourceURL
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("OpenUSD")
            .appendingPathComponent(root)
            .appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            return try Data(contentsOf: fixtureURL)
        }
    }
    #endif
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
    var crc32: UInt32 = 0
    var normalizesLineEndings: Bool = false
}

private extension Data {
    func normalizingCRLFLineEndings() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
    }
}

private func assertSDFUSDZResolverEntry(
    _ testCase: SDFZipEntryCase,
    in archive: USDZArchive,
    packageData: Data,
    sourcePath: String
) throws {
    let entry = try #require(archive.entry(at: testCase.path))
    let sourceData = try openSDFUSDZResolverFixture(sourcePath)
    #expect(entry.dataOffset == testCase.dataOffset)
    #expect(entry.size == testCase.size)
    #expect(entry.uncompressedSize == testCase.size)
    #expect(entry.compressionMethod == 0)
    #expect(!entry.isEncrypted)
    #expect(entry.isPayload64ByteAligned)
    let entryData = try #require(archive.entryData(at: testCase.path))
    #expect(entryData == sourceData)
    #expect(entryData.dropFirst(100).elementsEqual(sourceData.dropFirst(100)))
    try assertDataSlice(packageData, offset: testCase.dataOffset, equals: sourceData)
    #expect(try archive.assetData(at: testCase.path) == sourceData)
}

private func assertDataSlice(_ data: Data, offset: Int, equals expectedData: Data) throws {
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: expectedData.count)
    #expect(Data(data[start..<end]) == expectedData)
}
