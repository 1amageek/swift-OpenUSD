import Foundation
import Testing
import OpenUSD
@testable import OpenUSDC

@Suite("USDCSafetyAndPerformance", .serialized)
struct USDCSafetyAndPerformanceTests {

    // MARK: - Hostile input: truncation

    @Test(.timeLimit(.minutes(1)))
    func truncatedCrateDataAlwaysThrowsTypedImportError() throws {
        let fixture = try generatedFixture("minimal_mesh.usdc")
        for length in stride(from: 0, to: fixture.count, by: 3) {
            let truncated = Data(fixture.prefix(length))
            do {
                _ = try USDCReader().readLayer(from: truncated)
                Issue.record("Truncated crate of \(length) bytes decoded successfully.")
            } catch is USDError {
                // Every truncation must surface as a typed import error.
            } catch {
                Issue.record("Truncated crate of \(length) bytes threw \(error) instead of USDError.")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func corruptedSignatureIsRejected() throws {
        var fixture = try generatedFixture("minimal_mesh.usdc")
        fixture[fixture.startIndex] = UInt8(ascii: "X")
        #expect(throws: USDError.invalidData("USDC data is missing the PXR-USDC signature.")) {
            _ = try USDCReader().readLayer(from: fixture)
        }
    }

    // MARK: - Hostile input: section counts

    @Test(.timeLimit(.minutes(1)))
    func hostileSectionCountsAreRejectedWithoutOverallocation() throws {
        for sectionName in ["TOKENS", "STRINGS", "FIELDS", "FIELDSETS", "PATHS", "SPECS"] {
            let fixture = try generatedFixture("minimal_mesh.usdc")
            let crate = try USDCCrateFile(data: fixture)
            let section = try #require(crate.section(named: sectionName))
            var corrupted = fixture
            let countRange = (corrupted.startIndex + section.start)
                ..< (corrupted.startIndex + section.start + MemoryLayout<UInt64>.size)
            // Int.max element count: passes the platform-range check, so the
            // reader must reject it against the section size before allocating.
            corrupted.replaceSubrange(
                countRange,
                with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
            )
            do {
                _ = try USDCReader().readLayer(from: corrupted)
                Issue.record("Crate with hostile \(sectionName) count decoded successfully.")
            } catch is USDError {
                // Expected: rejected as a typed import error, not a crash or OOM.
            } catch {
                Issue.record("Hostile \(sectionName) count threw \(error) instead of USDError.")
            }
        }
    }

    // MARK: - Hostile input: recursion depth

    @Test(.timeLimit(.minutes(1)))
    func deeplyNestedDictionaryIsRejected() {
        let fixture = makeNestedDictionaryCrateFixture(nestingDepth: 33)
        do {
            _ = try USDCReader().readLayer(from: fixture)
            Issue.record("Deeply nested dictionary decoded successfully.")
        } catch USDError.invalidData(let message) {
            guard message == "USDC value nesting exceeds the maximum supported depth." else {
                Issue.record("Unexpected invalidData message: \(message)")
                return
            }
        } catch {
            Issue.record("Expected USDError.invalidData, got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func moderatelyNestedDictionaryDecodes() throws {
        let fixture = makeNestedDictionaryCrateFixture(nestingDepth: 3)
        let layer = try USDCReader().readLayer(from: fixture)
        let spec = try #require(layer.spec(at: "/Root"))
        var value = try #require(spec.fields["customData"])
        for _ in 0..<3 {
            guard case .dictionary(let entries) = value else {
                Issue.record("Expected nested dictionary, got \(value).")
                return
            }
            value = try #require(entries["nested"])
        }
        guard case .dictionary(let innermost) = value else {
            Issue.record("Expected empty innermost dictionary, got \(value).")
            return
        }
        #expect(innermost.isEmpty)
    }

    // MARK: - Missing pseudo-root

    @Test(.timeLimit(.minutes(1)))
    func crateWithoutPseudoRootSpecIsRejected() {
        let fixture = makeCrateFixtureWithoutPseudoRoot()
        #expect(throws: USDError.invalidData("USDC layer is missing the pseudo-root spec.")) {
            _ = try USDCReader().readLayer(from: fixture)
        }
        #expect(throws: USDError.invalidData("USDC scene is missing the pseudo-root spec.")) {
            _ = try USDCReader().read(from: fixture)
        }
    }

    // MARK: - Parse-once consistency

    @Test(.timeLimit(.minutes(1)))
    func structuralSectionsMatchIndividualSectionReaders() throws {
        let fixture = try generatedFixture("minimal_mesh.usdc")
        let crate = try USDCCrateFile(data: fixture)
        let sections = try crate.parseStructuralSections()
        #expect(sections.tokens == (try crate.readTokens()))
        #expect(sections.strings == (try crate.readStrings()))
        #expect(sections.fields == (try crate.readFields()))
        #expect(sections.fieldSetIndexes == (try crate.readFieldSetIndexes()))
        #expect(sections.paths == (try crate.readPaths()))
        #expect(sections.specs == (try crate.readSpecs()))
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "minimal_mesh.usdc",
            "translated_mesh.usdc",
            "rotated_mesh.usdc",
            "animated_mesh.usdc",
            "extent_mesh.usdc",
            "uv_mesh.usdc",
        ]
    )
    func layerAndSceneEntryPointsAgree(fixtureName: String) throws {
        let fixture = try generatedFixture(fixtureName)
        let layer = try USDCReader().readLayer(from: fixture)
        let scene = try USDCReader().read(from: fixture)
        #expect(layer.defaultPrim == scene.defaultPrim)
        if let metersPerUnit = layer.metersPerUnit {
            #expect(metersPerUnit == scene.metersPerUnit)
        }
        #expect(!scene.meshes.isEmpty)
        #expect(layer.spec(at: "/")?.specType == .pseudoRoot)
    }
}

// MARK: - Fixture builders

private func makeNestedDictionaryCrateFixture(nestingDepth: Int) -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = ["specifier", "Scope", "customData", "nested", "Root"]
    var valueData = Data()
    // Dictionaries reference children through absolute file offsets, so the
    // chain is emitted innermost-first directly into the value area that
    // makeUSDCFixture places immediately after the bootstrap.
    var childOffset = UInt64(USDCCrateFile.bootstrapByteCount + valueData.count)
    appendUSDCDictionary([], to: &valueData)
    for _ in 0..<nestingDepth {
        let wrapperOffset = UInt64(USDCCrateFile.bootstrapByteCount + valueData.count)
        appendUSDCDictionary([
            USDCEncodedDictionaryEntry(
                keyStringIndex: 0,
                valueRep: USDCCrateValueRep(
                    type: .dictionary,
                    isInlined: false,
                    isArray: false,
                    payload: childOffset
                )
            )
        ], to: &valueData)
        childOffset = wrapperOffset
    }
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 2,
            valueRep: USDCCrateValueRep(type: .dictionary, isInlined: false, isArray: false, payload: childOffset)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]
    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([3])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, 1, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 2,
            pathIndexes: [0, 1],
            elementTokenIndexes: [0, 4],
            jumps: [-1, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeCrateFixtureWithoutPseudoRoot() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = ["specifier", "Scope", "Root"]
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]
    return makeUSDCFixture(version: version, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 2,
            pathIndexes: [0, 1],
            elementTokenIndexes: [0, 2],
            jumps: [-1, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}
