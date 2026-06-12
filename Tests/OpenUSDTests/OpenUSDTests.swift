import Foundation
import Testing
import OpenUSD
@testable import OpenUSDC
import OpenUSDZ

@Suite("OpenUSD")
struct OpenUSDTests {
    @Test(.timeLimit(.minutes(1)))
    func usdcReaderReadsBootstrapAndTableOfContents() throws {
        let data = makeUSDCFixture(sections: [
            ("TOKENS", Data([0x01])),
            ("STRINGS", Data([0x02])),
            ("FIELDS", Data([0x03])),
            ("FIELDSETS", Data([0x04])),
            ("PATHS", Data([0x05])),
            ("SPECS", Data([0x06])),
        ])

        let crate = try USDCReader().readCrate(from: data)

        #expect(crate.version == USDCCrateVersion(major: 0, minor: 8, patch: 0))
        #expect(crate.tableOfContentsOffset > USDCCrateFile.bootstrapByteCount)
        #expect(crate.sections.map(\.name) == ["TOKENS", "STRINGS", "FIELDS", "FIELDSETS", "PATHS", "SPECS"])
        #expect(crate.section(named: "TOKENS")?.size == 1)
        try crate.requireStructuralSections()
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderReadsUncompressedLegacyTokens() throws {
        let tokenBytes = nullSeparatedTokenData(["", "Mesh", "points"])
        let tokenSection = makeUSDCTokenSection(version: USDCCrateVersion(major: 0, minor: 3, patch: 0), tokenData: tokenBytes)
        let data = makeUSDCFixture(
            version: USDCCrateVersion(major: 0, minor: 3, patch: 0),
            sections: [
                ("TOKENS", tokenSection),
            ]
        )

        let crate = try USDCReader().readCrate(from: data)

        #expect(try crate.readTokens() == ["", "Mesh", "points"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderReadsCompressedTokens() throws {
        let tokenBytes = nullSeparatedTokenData(["", "Mesh", "faceVertexIndices", "subdivisionScheme"])
        let tokenSection = makeUSDCTokenSection(version: USDCCrateVersion(major: 0, minor: 8, patch: 0), tokenData: tokenBytes)
        let data = makeUSDCFixture(sections: [
            ("TOKENS", tokenSection),
        ])

        let crate = try USDCReader().readCrate(from: data)

        #expect(try crate.readTokens() == ["", "Mesh", "faceVertexIndices", "subdivisionScheme"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderReadsCompressedStringFieldAndFieldSetTables() throws {
        let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
        let tokenBytes = nullSeparatedTokenData(["", "specifier", "points", "faceVertexIndices"])
        let fields = [
            USDCCrateField(
                tokenIndex: 1,
                valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 2)
            ),
            USDCCrateField(
                tokenIndex: 2,
                valueRep: USDCCrateValueRep(type: .vec3f, isInlined: false, isArray: true, payload: 128)
            ),
        ]
        let data = makeUSDCFixture(version: version, sections: [
            ("TOKENS", makeUSDCTokenSection(version: version, tokenData: tokenBytes)),
            ("STRINGS", makeUSDCStringsSection([1, 2])),
            ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
            ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [0, 1, UInt32.max])),
        ])

        let crate = try USDCReader().readCrate(from: data)

        #expect(try crate.readStringTokenIndexes() == [1, 2])
        #expect(try crate.readStrings() == ["specifier", "points"])
        let parsedFields = try crate.readFields()
        #expect(parsedFields == fields)
        #expect(parsedFields[0].valueRep.type == .specifier)
        #expect(parsedFields[0].valueRep.isInlined)
        #expect(parsedFields[1].valueRep.type == .vec3f)
        #expect(parsedFields[1].valueRep.isArray)
        #expect(parsedFields[1].valueRep.payload == 128)
        #expect(try crate.readFieldSetIndexes() == [0, 1, UInt32.max])
        #expect(try crate.readFieldSets() == [[0, 1]])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderReadsCompressedPathAndSpecTables() throws {
        let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
        let tokenBytes = nullSeparatedTokenData(["", "Root", "points", "specifier", "typeName"])
        let fields = [
            USDCCrateField(
                tokenIndex: 3,
                valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 2)
            ),
            USDCCrateField(
                tokenIndex: 4,
                valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 1)
            ),
        ]
        let specs = [
            USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
            USDCCrateSpec(pathIndex: 1, fieldSetIndex: 0, specType: .prim),
            USDCCrateSpec(pathIndex: 2, fieldSetIndex: 2, specType: .attribute),
        ]
        let data = makeUSDCFixture(version: version, sections: [
            ("TOKENS", makeUSDCTokenSection(version: version, tokenData: tokenBytes)),
            ("STRINGS", makeUSDCStringsSection([])),
            ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
            ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [0, UInt32.max, 1, UInt32.max])),
            ("PATHS", makeUSDCCompressedPathsSection(
                pathCount: 3,
                pathIndexes: [0, 1, 2],
                elementTokenIndexes: [0, 1, -2],
                jumps: [-1, -1, -2]
            )),
            ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
        ])

        let crate = try USDCReader().readCrate(from: data)

        #expect(try crate.readPaths() == ["/", "/Root", "/Root.points"])
        #expect(try crate.readSpecs() == specs)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderMaterializesMeshExchangeScene() throws {
        let fixture = makeUSDCMeshSceneFixture()

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.primPath == "/Triangle")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderPreservesNestedMeshPrimPath() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Model"
        {
            def Mesh "Triangle"
            {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                uniform token subdivisionScheme = "none"
            }
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)

        #expect(scene.meshes.map(\.primPath) == ["/Model/Triangle"])
        #expect(scene.meshes.map(\.name) == ["Triangle"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderUsesDefaultMetersPerUnitWhenLayerMetadataOmitsIt() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)

        // Upstream USD falls back to 0.01 (centimeters) when metersPerUnit is unauthored.
        #expect(scene.metersPerUnit == 0.01)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.map(\.name) == ["Triangle"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderUsesLayerMetadataUpAxisOnly() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
        )

        def Mesh "Triangle"
        {
            token upAxis = "sideways"
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)

        #expect(scene.upAxis == .y)
        #expect(scene.meshes.map(\.name) == ["Triangle"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderDoesNotStealNextAssignmentFromDefaultlessOptionalAttribute() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
        )

        def Mesh "Triangle"
        {
            uniform token subdivisionScheme
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.subdivisionScheme == nil)
        #expect(mesh.points.count == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderSkipsNonDefMeshPrimsWhenMaterializingScene() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Z"
        )

        over Mesh "Override"
        {
            point3f[] points = [(9, 9, 9), (10, 9, 9), (9, 10, 9)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }

        class Mesh "Template"
        {
            point3f[] points = [(8, 8, 8), (9, 8, 8), (8, 9, 8)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)

        #expect(scene.meshes.map(\.name) == ["Triangle"])
        #expect(scene.meshes.map(\.primPath) == ["/Triangle"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderIgnoresAttributeNamesInsideCommentsAndStrings() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            string note = "points = [(9, 9, 9), (10, 9, 9), (9, 10, 9)]"
            # int[] faceVertexCounts = [4]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderDoesNotReadMeshFieldsFromNestedMetadata() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
        )

        def Mesh "Triangle"
        {
            string note = "metadata" (
                customData = {
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                }
            )
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().read(from: data)
        }

        #expect(message.contains("points"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderPreservesPrimWorldTransforms() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene"
        {
            double3 xformOp:translate = (10, 20, 30)
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def "Instance"
            {
                double3 xformOp:translate = (1, 2, 3)
                uniform token[] xformOpOrder = ["xformOp:translate"]
            }
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)
        let sceneTransform = try #require(layer.primTransforms["/Scene"])
        let instanceTransform = try #require(layer.primTransforms["/Scene/Instance"])

        #expect(try sceneTransform.transform(USDPoint3D(x: 0, y: 0, z: 0)) == USDPoint3D(x: 10, y: 20, z: 30))
        #expect(try instanceTransform.transform(USDPoint3D(x: 0, y: 0, z: 0)) == USDPoint3D(x: 11, y: 22, z: 33))
    }

    @Test(.timeLimit(.minutes(1)))
    func transformMatrixReportsInvalidValueCountAsTypedError() throws {
        let matrix = USDTransformMatrix4x4(values: [1])

        #expect(throws: USDError.self) {
            _ = try matrix.transform(USDPoint3D(x: 0, y: 0, z: 0))
        }
        #expect(throws: USDError.self) {
            _ = try matrix.transform(normal: USDPoint3D(x: 0, y: 0, z: 1))
        }
        #expect(throws: USDError.self) {
            _ = try matrix.concatenating(.identity)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCMeshFixtureMaterializesMeshExchangeScene() throws {
        let fixture = try generatedFixture("minimal_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
        #expect(mesh.extent == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCPoint3DMeshFixtureReadsDoublePrecisionPoints() throws {
        let fixture = try generatedFixture("point3d_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.points.count == 3)
        #expect(mesh.points[0] == USDPoint3D(x: 0, y: 0, z: 0))
        let highPrecisionX = 12345.6789012345
        let highPrecisionY = 0.12345678901234568
        #expect(abs(mesh.points[1].x - highPrecisionX) <= 1.0e-12)
        #expect(abs(mesh.points[2].y - highPrecisionY) <= 1.0e-15)
        #expect(abs(mesh.points[1].x - Double(Float32(highPrecisionX))) > 1.0e-5)
        #expect(abs(mesh.points[2].y - Double(Float32(highPrecisionY))) > 1.0e-10)
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderReadsCompressedVec3fPointArray() throws {
        let fixture = makeUSDCMeshSceneFixture(compressedPoints: true)
        let crate = try USDCReader().readCrate(from: fixture)
        let pointsValueRep = try defaultFieldValueRep(in: crate, atPath: "/Triangle.points")

        #expect(pointsValueRep.type == .vec3f)
        #expect(pointsValueRep.isArray)
        #expect(pointsValueRep.isCompressed)

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderReadsCompressedTokenArrayXformOpOrder() throws {
        let fixture = makeUSDCMeshSceneFixture(compressedXformOpOrder: true)
        let crate = try USDCReader().readCrate(from: fixture)
        let xformOpOrderValueRep = try defaultFieldValueRep(in: crate, atPath: "/Triangle.xformOpOrder")

        #expect(xformOpOrderValueRep.type == .token)
        #expect(xformOpOrderValueRep.isArray)
        #expect(xformOpOrderValueRep.isCompressed)

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 3, z: 4),
            USDPoint3D(x: 2, y: 4, z: 4),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderUsesRequestedXformTimeSampleBeforeDefault() throws {
        let fixture = makeUSDCMeshSceneFixture(translateTimeSamples: [
            (timeCode: 1, value: USDPoint3D(x: 10, y: 0, z: 0)),
            (timeCode: 2, value: USDPoint3D(x: 20, y: 0, z: 0)),
        ])

        let scene = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 2))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 20, y: 0, z: 0),
            USDPoint3D(x: 21, y: 0, z: 0),
            USDPoint3D(x: 20, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderInterpolatesXformTimeSamples() throws {
        let fixture = makeUSDCMeshSceneFixture(translateTimeSamples: [
            (timeCode: 1, value: USDPoint3D(x: 10, y: 0, z: 0)),
            (timeCode: 3, value: USDPoint3D(x: 30, y: 0, z: 0)),
        ])

        let scene = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 2))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 20, y: 0, z: 0),
            USDPoint3D(x: 21, y: 0, z: 0),
            USDPoint3D(x: 20, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderInterpolatesPoint2AndDoubleArrayTimeSamples() throws {
        let fixture = makeUSDCMeshSceneFixture(
            textureCoordinateTimeSamples: [
                (timeCode: 1, values: [USDPoint2D(x: 0, y: 0)]),
                (timeCode: 3, values: [USDPoint2D(x: 1, y: 1)]),
            ],
            displayOpacityTimeSamples: [
                (timeCode: 1, values: [0.25]),
                (timeCode: 3, values: [0.75]),
            ]
        )

        let scene = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 2))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.textureCoordinates?.values == [USDPoint2D(x: 0.5, y: 0.5)])
        #expect(mesh.displayOpacity?.values == [0.5])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderRejectsLinearMatrixTransformTimeSamples() throws {
        let fixture = makeUSDCMeshSceneFixture(matrixTransformTimeSamples: [
            (timeCode: 1, values: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                10, 0, 0, 1,
            ]),
            (timeCode: 3, values: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                30, 0, 0, 1,
            ]),
        ])

        do {
            _ = try USDCReader().read(
                from: fixture,
                options: USDReadingOptions(timeCode: 2, timeSampleInterpolation: .linear)
            )
            Issue.record("Expected linear matrix transform timeSamples to fail.")
        } catch USDError.unsupportedFeature(let message) {
            #expect(message.contains("transform"))
            #expect(message.contains("linear interpolation"))
        } catch {
            Issue.record("Expected unsupportedFeature, got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesPrimWorldTransforms() throws {
        let fixture = makeUSDCMeshSceneFixture(compressedXformOpOrder: true)

        let layer = try USDCReader().readLayer(from: fixture)
        let meshTransform = try #require(layer.primTransforms["/Triangle"])

        #expect(try meshTransform.transform(USDPoint3D(x: 0, y: 0, z: 0)) == USDPoint3D(x: 2, y: 3, z: 4))
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCTranslatedMeshFixtureAppliesParentXform() throws {
        let fixture = try generatedFixture("translated_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.points == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 3, z: 4),
            USDPoint3D(x: 2, y: 4, z: 4),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCInvertedPivotFixtureAppliesInverseXformOp() throws {
        let fixture = try generatedFixture("inverted_pivot_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 1, y: 1, z: 0),
            USDPoint3D(x: 1, y: 2, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderReadsAuthoredMeshExtent() throws {
        let fixture = try generatedFixture("extent_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.extent == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCExtentMeshFixtureReadsAuthoredExtent() throws {
        let fixture = try generatedFixture("extent_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.extent == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 1, z: 0),
        ])
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderTransformsAuthoredExtentWithMeshPoints() throws {
        let fixture = makeUSDCMeshSceneFixture(compressedXformOpOrder: true, includeExtent: true)

        let scene = try USDCReader().read(from: fixture)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.points == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 3, z: 4),
            USDPoint3D(x: 2, y: 4, z: 4),
        ])
        #expect(mesh.extent == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 4, z: 4),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderTransformsAuthoredExtentWithMeshPoints() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Root"
        {
            double3 xformOp:translate = (2, 3, 4)
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def Mesh "Triangle"
            {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                point3f[] extent = [(0, 0, 0), (1, 1, 0)]
            }
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.points == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 3, z: 4),
            USDPoint3D(x: 2, y: 4, z: 4),
        ])
        #expect(mesh.extent == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 4, z: 4),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderReadsTimeSampledExtentWithoutDefaultValue() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] extent.timeSamples = {
                1: [(0, 0, 0), (1, 1, 0)],
                2: [(0, 0, 2), (1, 1, 2)]
            }
        }
        """.utf8)

        let firstScene = try USDAReader().read(from: data)
        let secondScene = try USDAReader().read(from: data, options: USDReadingOptions(timeCode: 2))

        #expect(firstScene.meshes.first?.extent == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 1, z: 0),
        ])
        #expect(secondScene.meshes.first?.extent == [
            USDPoint3D(x: 0, y: 0, z: 2),
            USDPoint3D(x: 1, y: 1, z: 2),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderReadsTimeSampledExtentWithoutDefaultValue() throws {
        let fixture = makeUSDCMeshSceneFixture(extentTimeSamples: [
            (timeCode: 1, points: [
                USDPoint3D(x: 0, y: 0, z: 0),
                USDPoint3D(x: 1, y: 1, z: 0),
            ]),
            (timeCode: 2, points: [
                USDPoint3D(x: 0, y: 0, z: 2),
                USDPoint3D(x: 1, y: 1, z: 2),
            ]),
        ])

        let firstScene = try USDCReader().read(from: fixture)
        let secondScene = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 2))

        #expect(firstScene.meshes.first?.extent == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 1, z: 0),
        ])
        #expect(secondScene.meshes.first?.extent == [
            USDPoint3D(x: 0, y: 0, z: 2),
            USDPoint3D(x: 1, y: 1, z: 2),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderIgnoresClosingDelimitersInsideArrayComments() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [
                (0, 0, 0), # ] must not close the points array
                (1, 0, 0),
                (0, 1, 0)
            ]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [
                0, # ] must not close the index array
                1,
                2
            ]
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCQuadMeshFixturePreservesFaceVertexTopology() throws {
        let fixture = try generatedFixture("quad_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Quad")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 1, y: 1, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [4])
        #expect(mesh.faceVertexIndices == [0, 1, 2, 3])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderReadsAuthoredSubdivisionScheme() throws {
        let fixture = try generatedFixture("subdivision_scheme_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Quad")
        #expect(mesh.faceVertexCounts == [4])
        #expect(mesh.faceVertexIndices == [0, 1, 2, 3])
        #expect(mesh.subdivisionScheme == "catmullClark")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCSubdivisionSchemeFixtureReadsAuthoredScheme() throws {
        let fixture = try generatedFixture("subdivision_scheme_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Quad")
        #expect(mesh.faceVertexCounts == [4])
        #expect(mesh.faceVertexIndices == [0, 1, 2, 3])
        #expect(mesh.subdivisionScheme == "catmullClark")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderReadsTextureCoordinatePrimvar() throws {
        let fixture = try generatedFixture("uv_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        let textureCoordinates = try #require(mesh.textureCoordinates)
        #expect(textureCoordinates.values == [
            USDPoint2D(x: 0, y: 0),
            USDPoint2D(x: 1, y: 0),
            USDPoint2D(x: 1, y: 1),
            USDPoint2D(x: 0, y: 1),
        ])
        #expect(textureCoordinates.indices == [0, 1, 2, 3])
        #expect(textureCoordinates.interpolation == "faceVarying")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCUVFixtureReadsTextureCoordinatePrimvar() throws {
        let fixture = try generatedFixture("uv_mesh.usdc")
        let crate = try USDCReader().readCrate(from: fixture)
        let stValueRep = try defaultFieldValueRep(in: crate, atPath: "/Quad.primvars:st")

        #expect(stValueRep.type == .vec2f)
        #expect(stValueRep.isArray)

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        let textureCoordinates = try #require(mesh.textureCoordinates)
        #expect(textureCoordinates.values == [
            USDPoint2D(x: 0, y: 0),
            USDPoint2D(x: 1, y: 0),
            USDPoint2D(x: 1, y: 1),
            USDPoint2D(x: 0, y: 1),
        ])
        #expect(textureCoordinates.indices == [0, 1, 2, 3])
        #expect(textureCoordinates.interpolation == "faceVarying")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderReadsDisplayColorAndOpacityPrimvars() throws {
        let fixture = try generatedFixture("display_color_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        let mesh = try #require(scene.meshes.first)
        let displayColor = try #require(mesh.displayColor)
        #expect(displayColor.values == [
            USDColorRGB(r: 1, g: 0, b: 0),
            USDColorRGB(r: 0, g: 1, b: 0),
            USDColorRGB(r: 0, g: 0, b: 1),
            USDColorRGB(r: 1, g: 1, b: 0),
        ])
        #expect(displayColor.indices == [0, 1, 2, 3])
        #expect(displayColor.interpolation == "faceVarying")

        let displayOpacity = try #require(mesh.displayOpacity)
        #expect(displayOpacity.values == [1, 0.75, 0.5, 0.25])
        #expect(displayOpacity.indices == [0, 1, 2, 3])
        #expect(displayOpacity.interpolation == "faceVarying")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCDisplayColorFixtureReadsDisplayPrimvars() throws {
        let fixture = try generatedFixture("display_color_mesh.usdc")
        let crate = try USDCReader().readCrate(from: fixture)
        let colorValueRep = try defaultFieldValueRep(in: crate, atPath: "/Quad.primvars:displayColor")
        let opacityValueRep = try defaultFieldValueRep(in: crate, atPath: "/Quad.primvars:displayOpacity")

        #expect(colorValueRep.type == .vec3f)
        #expect(colorValueRep.isArray)
        #expect(opacityValueRep.type == .float)
        #expect(opacityValueRep.isArray)

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Quad")
        let mesh = try #require(scene.meshes.first)
        let displayColor = try #require(mesh.displayColor)
        #expect(displayColor.values == [
            USDColorRGB(r: 1, g: 0, b: 0),
            USDColorRGB(r: 0, g: 1, b: 0),
            USDColorRGB(r: 0, g: 0, b: 1),
            USDColorRGB(r: 1, g: 1, b: 0),
        ])
        #expect(displayColor.indices == [0, 1, 2, 3])
        #expect(displayColor.interpolation == "faceVarying")

        let displayOpacity = try #require(mesh.displayOpacity)
        #expect(displayOpacity.values == [1, 0.75, 0.5, 0.25])
        #expect(displayOpacity.indices == [0, 1, 2, 3])
        #expect(displayOpacity.interpolation == "faceVarying")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsTextureCoordinateIndexOutsideValueRange() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Quad"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Quad"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)]
            int[] faceVertexCounts = [4]
            int[] faceVertexIndices = [0, 1, 2, 3]
            texCoord2f[] primvars:st = [(0, 0), (1, 0)] (
                interpolation = "faceVarying"
            )
            int[] primvars:st:indices = [0, 1, 2, 0]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)

        #expect(throws: USDError.self) {
            _ = try USDAReader().read(from: data)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCRotatedMeshFixtureAppliesParentAxisRotations() throws {
        let fixture = try generatedFixture("rotated_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 3)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let rotateXMesh = try #require(meshesByName["TriangleX"])
        expectPointsApproximatelyEqual(rotateXMesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 0, z: 1),
        ])
        let rotateYMesh = try #require(meshesByName["TriangleY"])
        expectPointsApproximatelyEqual(rotateYMesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 0, y: 0, z: -1),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        let rotateZMesh = try #require(meshesByName["TriangleZ"])
        expectPointsApproximatelyEqual(rotateZMesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
            USDPoint3D(x: -1, y: 0, z: 0),
        ])
        for mesh in [rotateXMesh, rotateYMesh, rotateZMesh] {
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCNormalsMeshFixtureReadsVertexNormals() throws {
        let fixture = try generatedFixture("normals_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 0, z: 1),
        ])
        expectPointsApproximatelyEqual(mesh.normals, [
            USDPoint3D(x: 0, y: -1, z: 0),
            USDPoint3D(x: 0, y: -1, z: 0),
            USDPoint3D(x: 0, y: -1, z: 0),
        ])
        #expect(mesh.normalsInterpolation == "vertex")
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderReadsMeshOrientation() throws {
        let fixture = try generatedFixture("left_handed_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.orientation == .leftHanded)
        expectPointsApproximatelyEqual(mesh.normals, [
            USDPoint3D(x: 0, y: 0, z: -1),
            USDPoint3D(x: 0, y: 0, z: -1),
            USDPoint3D(x: 0, y: 0, z: -1),
        ])
        #expect(mesh.normalsInterpolation == "vertex")
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCLeftHandedMeshFixtureReadsOrientation() throws {
        let fixture = try generatedFixture("left_handed_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.orientation == .leftHanded)
        expectPointsApproximatelyEqual(mesh.normals, [
            USDPoint3D(x: 0, y: 0, z: -1),
            USDPoint3D(x: 0, y: 0, z: -1),
            USDPoint3D(x: 0, y: 0, z: -1),
        ])
        #expect(mesh.normalsInterpolation == "vertex")
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCCombinedRotationFixtureAppliesPackedEulerRotation() throws {
        let fixture = try generatedFixture("combined_rotation_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 6)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let expectedPointsByName: [String: [USDPoint3D]] = [
            "TriangleXYZ": [
                USDPoint3D(x: 0, y: 0, z: -1),
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
            ],
            "TriangleXZY": [
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: -1),
            ],
            "TriangleYXZ": [
                USDPoint3D(x: -1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: 1, z: 0),
            ],
            "TriangleYZX": [
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: -1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
            ],
            "TriangleZXY": [
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: -1, z: 0),
            ],
            "TriangleZYX": [
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: -1, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
            ],
        ]
        for (name, expectedPoints) in expectedPointsByName {
            let mesh = try #require(meshesByName[name])
            expectPointsApproximatelyEqual(mesh.points, expectedPoints)
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCOrientFixtureAppliesQuaternionTransforms() throws {
        let fixture = try generatedFixture("orient_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 3)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let expectedPointsByName: [String: [USDPoint3D]] = [
            "TriangleQuatf": [
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: -1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
            ],
            "TriangleQuatd": [
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: -1, z: 0),
            ],
            "TriangleZero": [
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
            ],
        ]
        for (name, expectedPoints) in expectedPointsByName {
            let mesh = try #require(meshesByName[name])
            expectPointsApproximatelyEqual(mesh.points, expectedPoints)
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCScalarXformFixtureAppliesScalarTranslateAndScaleOps() throws {
        let fixture = try generatedFixture("scalar_xform_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 6)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let expectedPointsByName: [String: [USDPoint3D]] = [
            "TriangleTranslateX": [
                USDPoint3D(x: 3, y: 1, z: 1),
                USDPoint3D(x: 4, y: 1, z: 1),
                USDPoint3D(x: 3, y: 2, z: 1),
            ],
            "TriangleTranslateY": [
                USDPoint3D(x: 1, y: 4, z: 1),
                USDPoint3D(x: 2, y: 4, z: 1),
                USDPoint3D(x: 1, y: 5, z: 1),
            ],
            "TriangleTranslateZ": [
                USDPoint3D(x: 1, y: 1, z: 5),
                USDPoint3D(x: 2, y: 1, z: 5),
                USDPoint3D(x: 1, y: 2, z: 5),
            ],
            "TriangleScaleX": [
                USDPoint3D(x: 2, y: 1, z: 1),
                USDPoint3D(x: 4, y: 1, z: 1),
                USDPoint3D(x: 2, y: 2, z: 1),
            ],
            "TriangleScaleY": [
                USDPoint3D(x: 1, y: 3, z: 1),
                USDPoint3D(x: 2, y: 3, z: 1),
                USDPoint3D(x: 1, y: 6, z: 1),
            ],
            "TriangleScaleZ": [
                USDPoint3D(x: 1, y: 1, z: 4),
                USDPoint3D(x: 2, y: 1, z: 4),
                USDPoint3D(x: 1, y: 2, z: 4),
            ],
        ]
        for (name, expectedPoints) in expectedPointsByName {
            let mesh = try #require(meshesByName[name])
            expectPointsApproximatelyEqual(mesh.points, expectedPoints)
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDATranslatedMeshFixtureAppliesParentXform() throws {
        let fixture = try generatedFixture("translated_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.points == [
            USDPoint3D(x: 2, y: 3, z: 4),
            USDPoint3D(x: 3, y: 3, z: 4),
            USDPoint3D(x: 2, y: 4, z: 4),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDAInvertedPivotFixtureAppliesInverseXformOp() throws {
        let fixture = try generatedFixture("inverted_pivot_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 1, y: 1, z: 0),
            USDPoint3D(x: 1, y: 2, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderResetXformStackBlocksAncestorTransform() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Root"
        {
            double3 xformOp:translate = (10, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def Xform "Child"
            {
                double3 xformOp:translate = (1, 0, 0)
                uniform token[] xformOpOrder = ["!resetXformStack!", "xformOp:translate"]

                def Mesh "Triangle"
                {
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                    uniform token subdivisionScheme = "none"
                }
            }
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 2, y: 0, z: 0),
            USDPoint3D(x: 1, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDARotatedMeshFixtureAppliesParentAxisRotations() throws {
        let fixture = try generatedFixture("rotated_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 3)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let rotateXMesh = try #require(meshesByName["TriangleX"])
        expectPointsApproximatelyEqual(rotateXMesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 0, z: 1),
        ])
        let rotateYMesh = try #require(meshesByName["TriangleY"])
        expectPointsApproximatelyEqual(rotateYMesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 0, y: 0, z: -1),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        let rotateZMesh = try #require(meshesByName["TriangleZ"])
        expectPointsApproximatelyEqual(rotateZMesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
            USDPoint3D(x: -1, y: 0, z: 0),
        ])
        for mesh in [rotateXMesh, rotateYMesh, rotateZMesh] {
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDANormalsMeshFixtureReadsVertexNormals() throws {
        let fixture = try generatedFixture("normals_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 0, z: 1),
        ])
        expectPointsApproximatelyEqual(mesh.normals, [
            USDPoint3D(x: 0, y: -1, z: 0),
            USDPoint3D(x: 0, y: -1, z: 0),
            USDPoint3D(x: 0, y: -1, z: 0),
        ])
        #expect(mesh.normalsInterpolation == "vertex")
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderTransformsNormalsWithFullInverseMatrix() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Root"
        {
            matrix4d xformOp:transform = (
                (1, 0.5, 0, 0),
                (2, 3, 0, 0),
                (1, 0, 4, 0),
                (0, 0, 0, 1)
            )
            uniform token[] xformOpOrder = ["xformOp:transform"]

            def Mesh "Triangle"
            {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                normal3f[] normals = [(1, 1, 1), (1, 1, 1), (1, 1, 1)] (
                    interpolation = "vertex"
                )
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
            }
        }
        """.utf8)

        let scene = try USDAReader().read(from: data)
        let mesh = try #require(scene.meshes.first)

        expectPointsApproximatelyEqual(mesh.normals, [
            USDPoint3D(x: 0.927477791813676, y: -0.37099111672547056, z: -0.0463738895906838),
            USDPoint3D(x: 0.927477791813676, y: -0.37099111672547056, z: -0.0463738895906838),
            USDPoint3D(x: 0.927477791813676, y: -0.37099111672547056, z: -0.0463738895906838),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDACombinedRotationFixtureAppliesPackedEulerRotation() throws {
        let fixture = try generatedFixture("combined_rotation_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 6)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let expectedPointsByName: [String: [USDPoint3D]] = [
            "TriangleXYZ": [
                USDPoint3D(x: 0, y: 0, z: -1),
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
            ],
            "TriangleXZY": [
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: -1),
            ],
            "TriangleYXZ": [
                USDPoint3D(x: -1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: 1, z: 0),
            ],
            "TriangleYZX": [
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: -1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
            ],
            "TriangleZXY": [
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: -1, z: 0),
            ],
            "TriangleZYX": [
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: -1, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
            ],
        ]
        for (name, expectedPoints) in expectedPointsByName {
            let mesh = try #require(meshesByName[name])
            expectPointsApproximatelyEqual(mesh.points, expectedPoints)
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDAOrientFixtureAppliesQuaternionTransforms() throws {
        let fixture = try generatedFixture("orient_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 3)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let expectedPointsByName: [String: [USDPoint3D]] = [
            "TriangleQuatf": [
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: -1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
            ],
            "TriangleQuatd": [
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 0, y: -1, z: 0),
            ],
            "TriangleZero": [
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 1, z: 0),
                USDPoint3D(x: 0, y: 0, z: 1),
            ],
        ]
        for (name, expectedPoints) in expectedPointsByName {
            let mesh = try #require(meshesByName[name])
            expectPointsApproximatelyEqual(mesh.points, expectedPoints)
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDAScalarXformFixtureAppliesScalarTranslateAndScaleOps() throws {
        let fixture = try generatedFixture("scalar_xform_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        #expect(scene.defaultPrim == "Root")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 6)
        let meshesByName = Dictionary(uniqueKeysWithValues: scene.meshes.compactMap { mesh in
            mesh.name.map { ($0, mesh) }
        })
        let expectedPointsByName: [String: [USDPoint3D]] = [
            "TriangleTranslateX": [
                USDPoint3D(x: 3, y: 1, z: 1),
                USDPoint3D(x: 4, y: 1, z: 1),
                USDPoint3D(x: 3, y: 2, z: 1),
            ],
            "TriangleTranslateY": [
                USDPoint3D(x: 1, y: 4, z: 1),
                USDPoint3D(x: 2, y: 4, z: 1),
                USDPoint3D(x: 1, y: 5, z: 1),
            ],
            "TriangleTranslateZ": [
                USDPoint3D(x: 1, y: 1, z: 5),
                USDPoint3D(x: 2, y: 1, z: 5),
                USDPoint3D(x: 1, y: 2, z: 5),
            ],
            "TriangleScaleX": [
                USDPoint3D(x: 2, y: 1, z: 1),
                USDPoint3D(x: 4, y: 1, z: 1),
                USDPoint3D(x: 2, y: 2, z: 1),
            ],
            "TriangleScaleY": [
                USDPoint3D(x: 1, y: 3, z: 1),
                USDPoint3D(x: 2, y: 3, z: 1),
                USDPoint3D(x: 1, y: 6, z: 1),
            ],
            "TriangleScaleZ": [
                USDPoint3D(x: 1, y: 1, z: 4),
                USDPoint3D(x: 2, y: 1, z: 4),
                USDPoint3D(x: 1, y: 2, z: 4),
            ],
        ]
        for (name, expectedPoints) in expectedPointsByName {
            let mesh = try #require(meshesByName[name])
            expectPointsApproximatelyEqual(mesh.points, expectedPoints)
            #expect(mesh.faceVertexCounts == [3])
            #expect(mesh.faceVertexIndices == [0, 1, 2])
            #expect(mesh.subdivisionScheme == "none")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCTimeSampledMeshFixtureUsesFirstSampleSnapshot() throws {
        let fixture = try generatedFixture("animated_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCLayerReaderPreservesTypedPointTimeSamples() throws {
        let fixture = try generatedFixture("animated_mesh.usdc")
        let expectedSamples = [
            SdfTimeSample(timeCode: 1, value: .point3Array([
                USDPoint3D(x: 0, y: 0, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 1, z: 0),
            ])),
            SdfTimeSample(timeCode: 2, value: .point3Array([
                USDPoint3D(x: 0, y: 0, z: 1),
                USDPoint3D(x: 1, y: 0, z: 1),
                USDPoint3D(x: 0, y: 1, z: 1),
            ])),
        ]

        let layer = try USDCReader().readLayer(from: fixture)
        let pointsSpec = try #require(layer.spec(at: "/Triangle.points"))
        let sdfLayer = try SdfLayer(usdcLayer: layer)
        let sdfPointsSpec = try #require(try sdfLayer.spec(at: "/Triangle.points"))

        #expect(pointsSpec.fields["timeSamples"] == .timeSamples(expectedSamples))
        #expect(sdfPointsSpec.fields["timeSamples"] == .timeSamples(expectedSamples))
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDATimeSampledMeshFixtureUsesRequestedSnapshot() throws {
        let fixture = try generatedFixture("animated_mesh.usda")

        let scene = try USDAReader().read(from: fixture, options: USDReadingOptions(timeCode: 2))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 1),
            USDPoint3D(x: 1, y: 0, z: 1),
            USDPoint3D(x: 0, y: 1, z: 1),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDATimeSampledMeshFixtureInterpolatesRequestedSnapshot() throws {
        let fixture = try generatedFixture("animated_mesh.usda")

        let scene = try USDAReader().read(from: fixture, options: USDReadingOptions(timeCode: 1.5))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0.5),
            USDPoint3D(x: 1, y: 0, z: 0.5),
            USDPoint3D(x: 0, y: 1, z: 0.5),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDATimeSampledMeshFixtureCanUseHeldInterpolation() throws {
        let fixture = try generatedFixture("animated_mesh.usda")

        let scene = try USDAReader().read(
            from: fixture,
            options: USDReadingOptions(timeCode: 1.5, timeSampleInterpolation: .held)
        )

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCTimeSampledMeshFixtureCanUseHeldInterpolation() throws {
        let fixture = try generatedFixture("animated_mesh.usdc")

        let scene = try USDCReader().read(
            from: fixture,
            options: USDReadingOptions(timeCode: 1.5, timeSampleInterpolation: .held)
        )

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCTimeSampledMeshFixtureUsesRequestedSnapshot() throws {
        let fixture = try generatedFixture("animated_mesh.usdc")

        let scene = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 2))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 1),
            USDPoint3D(x: 1, y: 0, z: 1),
            USDPoint3D(x: 0, y: 1, z: 1),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCTimeSampledMeshFixtureInterpolatesRequestedSnapshot() throws {
        let fixture = try generatedFixture("animated_mesh.usdc")

        let scene = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 1.5))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0.5),
            USDPoint3D(x: 1, y: 0, z: 0.5),
            USDPoint3D(x: 0, y: 1, z: 0.5),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCBlockedValueFixtureUsesFirstUnblockedSampleSnapshot() throws {
        let fixture = try generatedFixture("blocked_values_mesh.usdc")

        let scene = try USDCReader().read(from: fixture)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.metersPerUnit == 1)
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "Triangle")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 2),
            USDPoint3D(x: 1, y: 0, z: 2),
            USDPoint3D(x: 0, y: 1, z: 2),
        ])
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
        #expect(mesh.subdivisionScheme == nil)
        #expect(mesh.effectiveSubdivisionScheme == "catmullClark")
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDABlockedValueFixtureUsesFirstUnblockedSampleSnapshot() throws {
        let fixture = try generatedFixture("blocked_values_mesh.usda")

        let scene = try USDAReader().read(from: fixture)

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 2),
            USDPoint3D(x: 1, y: 0, z: 2),
            USDPoint3D(x: 0, y: 1, z: 2),
        ])
        #expect(mesh.subdivisionScheme == nil)
        #expect(mesh.effectiveSubdivisionScheme == "catmullClark")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderTreatsExactBlockedPointTimeSampleAsMissingRequiredField() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(9, 9, 9), (10, 9, 9), (9, 10, 9)]
            point3f[] points.timeSamples = {
                1: None,
                2: [(0, 0, 2), (1, 0, 2), (0, 1, 2)]
            }
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)

        do {
            _ = try USDAReader().read(from: data, options: USDReadingOptions(timeCode: 1))
            Issue.record("Expected blocked points to be reported as a missing required field.")
        } catch USDError.missingRequiredField(let field) {
            #expect(field == "points")
        } catch {
            Issue.record("Expected missingRequiredField(\"points\"), got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderTreatsRequiredMeshArrayNoneAsMissingField() throws {
        let cases: [(field: String, layerBody: String)] = [
            (
                field: "points",
                layerBody: """
                point3f[] points = None
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                """
            ),
            (
                field: "faceVertexCounts",
                layerBody: """
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = None
                int[] faceVertexIndices = [0, 1, 2]
                """
            ),
            (
                field: "faceVertexIndices",
                layerBody: """
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = None
                """
            ),
        ]

        for testCase in cases {
            let data = Data("""
            #usda 1.0
            (
                defaultPrim = "Triangle"
                metersPerUnit = 1
                upAxis = "Z"
            )

            def Mesh "Triangle"
            {
            \(testCase.layerBody)
            }
            """.utf8)

            do {
                _ = try USDAReader().read(from: data)
                Issue.record("Expected \(testCase.field) to be reported as a missing required field.")
            } catch USDError.missingRequiredField(let field) {
                #expect(field == testCase.field)
            } catch {
                Issue.record("Expected missingRequiredField(\"\(testCase.field)\"), got \(error).")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsMalformedPointTimeSampleEntries() throws {
        let timeSamplesBodies = [
            """
            1: Nonee,
            2: [(0, 0, 2), (1, 0, 2), (0, 1, 2)]
            """,
            """
            1: [(0, 0, 1), (1, 0, 1), (0, 1, 1)],
            garbage
            """,
            """
            1: [(0, 0, 1), garbage, (1, 0, 1), (0, 1, 1)],
            2: [(0, 0, 2), (1, 0, 2), (0, 1, 2)]
            """,
            """
            1: [(0, 0, 1), (1, 0, 1), (0, 1, 1)],
            1: [(0, 0, 2), (1, 0, 2), (0, 1, 2)]
            """,
            """
            1:
            """,
        ]

        for timeSamplesBody in timeSamplesBodies {
            let data = Data("""
            #usda 1.0
            (
                defaultPrim = "Triangle"
                metersPerUnit = 1
                upAxis = "Z"
            )

            def Mesh "Triangle"
            {
                point3f[] points = [(9, 9, 9), (10, 9, 9), (9, 10, 9)]
                point3f[] points.timeSamples = {
            \(timeSamplesBody)
                }
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
            }
            """.utf8)

            do {
                _ = try USDAReader().read(from: data, options: USDReadingOptions(timeCode: 1))
                Issue.record("Expected malformed timeSamples to fail.")
            } catch USDError.invalidData {
            } catch {
                Issue.record("Expected USDError.invalidData, got \(error).")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsMalformedNumericTupleContent() throws {
        let cases: [(label: String, meshBody: String)] = [
            (
                label: "points",
                meshBody: """
                    point3f[] points = [(0, 0, 0), garbage, (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                """
            ),
            (
                label: "texture coordinates",
                meshBody: """
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                    texCoord2f[] primvars:st = [(0, 0), garbage, (1, 0), (0, 1)]
                    int[] primvars:st:indices = [0, 1, 2]
                """
            ),
            (
                label: "display color",
                meshBody: """
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                    color3f[] primvars:displayColor = [(1, 0, 0), garbage]
                """
            ),
            (
                label: "transform tuple",
                meshBody: """
                    double3 xformOp:translate = (1, garbage, 2, 3)
                    uniform token[] xformOpOrder = ["xformOp:translate"]
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                """
            ),
        ]

        for testCase in cases {
            let data = Data("""
            #usda 1.0
            (
                defaultPrim = "Triangle"
                metersPerUnit = 1
                upAxis = "Z"
            )

            def Mesh "Triangle"
            {
            \(testCase.meshBody)
            }
            """.utf8)

            do {
                _ = try USDAReader().read(from: data)
                Issue.record("Expected malformed \(testCase.label) tuple content to fail.")
            } catch USDError.invalidData {
            } catch {
                Issue.record("Expected USDError.invalidData for \(testCase.label), got \(error).")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderTreatsExactBlockedPointTimeSampleAsMissingRequiredField() throws {
        let fixture = try generatedFixture("blocked_values_mesh.usdc")

        do {
            _ = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 1))
            Issue.record("Expected blocked points to be reported as a missing required field.")
        } catch USDError.missingRequiredField(let field) {
            #expect(field == "points")
        } catch {
            Issue.record("Expected missingRequiredField(\"points\"), got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedUSDCBlockedRequiredDefaultFixtureReportsMissingField() throws {
        let fixture = try generatedFixture("blocked_required_default_mesh.usdc")

        do {
            _ = try USDCReader().read(from: fixture)
            Issue.record("Expected blocked points to be reported as a missing required field.")
        } catch USDError.missingRequiredField(let field) {
            #expect(field == "points")
        } catch {
            Issue.record("Expected missingRequiredField(\"points\"), got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderTreatsExactBlockedTopologyTimeSamplesAsMissingRequiredFields() throws {
        for field in ["faceVertexCounts", "faceVertexIndices"] {
            let fixture = makeUSDCMeshSceneFixture(blockedTopologyTimeSampleField: field)

            do {
                _ = try USDCReader().read(from: fixture, options: USDReadingOptions(timeCode: 1))
                Issue.record("Expected blocked \(field) to be reported as a missing required field.")
            } catch USDError.missingRequiredField(let missingField) {
                #expect(missingField == field)
            } catch {
                Issue.record("Expected missingRequiredField(\"\(field)\"), got \(error).")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderUsesRequestedTimeSampledTopologyWhenDefaultAlsoExists() throws {
        let countsFixture = makeUSDCMeshSceneFixture(
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 2],
            sampledTopologyTimeSampleField: "faceVertexCounts",
            sampledTopologyTimeSampleValues: [1, 2]
        )
        let countsScene = try USDCReader().read(from: countsFixture, options: USDReadingOptions(timeCode: 1))
        let countsMesh = try #require(countsScene.meshes.first)
        #expect(countsMesh.faceVertexCounts == [1, 2])
        #expect(countsMesh.faceVertexIndices == [0, 1, 2])

        let indicesFixture = makeUSDCMeshSceneFixture(
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 2],
            sampledTopologyTimeSampleField: "faceVertexIndices",
            sampledTopologyTimeSampleValues: [2, 1, 0]
        )
        let indicesScene = try USDCReader().read(from: indicesFixture, options: USDReadingOptions(timeCode: 1))
        let indicesMesh = try #require(indicesScene.meshes.first)
        #expect(indicesMesh.faceVertexCounts == [3])
        #expect(indicesMesh.faceVertexIndices == [2, 1, 0])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderUsesTimeSamplesWhenTopologyDefaultIsValueBlocked() throws {
        let countsFixture = makeUSDCMeshSceneFixture(
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 2],
            sampledTopologyTimeSampleField: "faceVertexCounts",
            sampledTopologyTimeSampleValues: [1, 2],
            valueBlockedTopologyDefaultField: "faceVertexCounts"
        )
        let countsScene = try USDCReader().read(from: countsFixture)
        let countsMesh = try #require(countsScene.meshes.first)
        #expect(countsMesh.faceVertexCounts == [1, 2])
        #expect(countsMesh.faceVertexIndices == [0, 1, 2])

        let indicesFixture = makeUSDCMeshSceneFixture(
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 2],
            sampledTopologyTimeSampleField: "faceVertexIndices",
            sampledTopologyTimeSampleValues: [2, 1, 0],
            valueBlockedTopologyDefaultField: "faceVertexIndices"
        )
        let indicesScene = try USDCReader().read(from: indicesFixture)
        let indicesMesh = try #require(indicesScene.meshes.first)
        #expect(indicesMesh.faceVertexCounts == [3])
        #expect(indicesMesh.faceVertexIndices == [2, 1, 0])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsInvalidMeshTopology() throws {
        let cases: [(counts: [Int], indices: [Int], expectedMessage: String)] = [
            (counts: [4], indices: [0, 1, 2], expectedMessage: "does not match"),
            (counts: [3], indices: [0, 1, 3], expectedMessage: "outside"),
            (counts: [3], indices: [0, 1, -1], expectedMessage: "outside"),
            (counts: [0], indices: [0], expectedMessage: "non-positive"),
        ]

        for testCase in cases {
            let countsLiteral = testCase.counts.map(String.init).joined(separator: ", ")
            let indicesLiteral = testCase.indices.map(String.init).joined(separator: ", ")
            let data = Data("""
            #usda 1.0
            (
                defaultPrim = "Triangle"
                metersPerUnit = 1
                upAxis = "Z"
            )

            def Mesh "Triangle"
            {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [\(countsLiteral)]
                int[] faceVertexIndices = [\(indicesLiteral)]
            }
            """.utf8)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().read(from: data)
            }
            #expect(message.contains(testCase.expectedMessage))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcReaderRejectsInvalidMeshTopology() throws {
        let cases: [(counts: [Int32], indices: [Int32], expectedMessage: String)] = [
            (counts: [4], indices: [0, 1, 2], expectedMessage: "does not match"),
            (counts: [3], indices: [0, 1, 3], expectedMessage: "outside"),
            (counts: [3], indices: [0, 1, -1], expectedMessage: "outside"),
            (counts: [0], indices: [0], expectedMessage: "non-positive"),
        ]

        for testCase in cases {
            let fixture = makeUSDCMeshSceneFixture(
                faceVertexCounts: testCase.counts,
                faceVertexIndices: testCase.indices
            )
            let message = try usdImportFailureMessage {
                _ = try USDCReader().read(from: fixture)
            }
            #expect(message.contains(testCase.expectedMessage))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderMaterializesUSDCDefaultLayerMeshExchangeScene() throws {
        let fixture = makeUSDCMeshSceneFixture()
        let package = makeUSDZFixture(entries: [
            ("scene.usdc", fixture),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.defaultPrim == "Triangle")
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.first?.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderSkipsUSDCNonDefMeshLayersWhenBuildingLayerGraph() throws {
        for payload in [UInt64(1), UInt64(2)] {
            let fixture = makeUSDCMeshSceneFixture(meshSpecifierPayload: payload)
            let package = makeUSDZFixture(entries: [
                ("scene.usdc", fixture),
            ], alignPayloads: true)

            let graph = try USDZReader().readLayerGraph(from: package)
            let layer = try #require(graph.layers.first)

            #expect(graph.rootPath == "scene.usdc")
            #expect(layer.path == "scene.usdc")
            #expect(layer.defaultPrim == "Triangle")
            #expect(layer.hasScene == false)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDFileFormatCrateFixtureReadsStructuralTables() throws {
        let data = try openUSDFixture("testUsdFileFormats/crate.usd")

        let crate = try USDCReader().readCrate(from: data)

        #expect(crate.version == USDCCrateVersion(major: 0, minor: 0, patch: 1))
        try crate.requireStructuralSections()
        #expect(try crate.readTokens().contains("specifier"))
        #expect(try crate.readStringTokenIndexes() == [])
        #expect(!((try crate.readFields()).isEmpty))
        #expect(!((try crate.readFieldSetIndexes()).isEmpty))
        #expect(try crate.readPaths() == ["/", "/AirConditioner", "/Scope"])
        let specs = try crate.readSpecs()
        #expect(specs.count == 3)
        #expect(specs[1] == USDCCrateSpec(pathIndex: 2, fieldSetIndex: 2, specType: .prim))
        let tokens = try crate.readTokens()
        let fields = try crate.readFields()
        let fieldSetIndexes = try crate.readFieldSetIndexes()
        #expect(fieldSetIndexes[2...3].map { $0 } == [0, 1])
        #expect(tokens[Int(fields[1].tokenIndex)] == "typeName")
        #expect(fields[1].valueRep.type == .token)
        #expect(fields[1].valueRep.isInlined)
        #expect(fields[1].valueRep.payload == 3)
        #expect(tokens[Int(fields[1].valueRep.payload)] == "Scope")
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDFileFormatCrateFixtureKeepsLazyReadsStableAfterSourceDataMutation() throws {
        var data = try openUSDFixture("testUsdFileFormats/crate.usd")
        let crate = try USDCReader().readCrate(from: data)
        let tokens = try crate.readTokens()
        let paths = try crate.readPaths()
        let specs = try crate.readSpecs()

        data[0] = 0

        #expect(try crate.readTokens() == tokens)
        #expect(try crate.readPaths() == paths)
        #expect(try crate.readSpecs() == specs)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDFileFormatCrateFixtureReadsLayerSpecs() throws {
        let data = try openUSDFixture("testUsdFileFormats/crate.usd")

        let layer = try USDCReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.specs.map(\.path) == ["/", "/AirConditioner", "/Scope"])
        #expect(layer.spec(at: "/")?.specType == .pseudoRoot)
        let airConditioner = try #require(layer.spec(at: "/AirConditioner"))
        #expect(airConditioner.specType == .prim)
        #expect(airConditioner.specifier == .def)
        #expect(airConditioner.typeName == nil)
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.specifier == .def)
        #expect(scope.typeName == "Scope")
        #expect(scope.fieldNames.contains("typeName"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDFileFormatAsciiFixtureReadsLayerSpecs() throws {
        let data = try openUSDFixture("testUsdFileFormats/ascii.usd")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.isEmpty)
        #expect(layer.specs.map(\.path) == ["/", "/AirConditioner", "/Scope"])
        #expect(layer.spec(at: "/")?.specType == .pseudoRoot)
        let airConditioner = try #require(layer.spec(at: "/AirConditioner"))
        #expect(airConditioner.specType == .prim)
        #expect(airConditioner.specifier == .def)
        #expect(airConditioner.typeName == nil)
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.specifier == .def)
        #expect(scope.typeName == "Scope")
        #expect(scope.fieldNames.contains("typeName"))
        #expect(layer.primTransforms.keys.sorted() == ["/AirConditioner", "/Scope"])
        #expect(layer.primTransforms.values.allSatisfy { $0 == .identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingEmptyFixturesReadLayers() throws {
        for fixturePath in [
            "testSdfParsing.testenv/01_empty.usda",
            "testSdfParsing.testenv/203_newlines.usda",
            "testSdfParsing.testenv/204_really_empty.usda",
        ] {
            let layer = try USDAReader().readLayer(from: openUSDFixture(fixturePath))

            #expect(layer.defaultPrim == nil)
            #expect(layer.metersPerUnit == nil)
            #expect(layer.upAxis == nil)
            #expect(layer.composition.isEmpty)
            #expect(layer.primTransforms.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingSimpleFixtureReadsDefAndOverPrimSpecsAndTransforms() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/02_simple.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.isEmpty)
        #expect(layer.spec(at: "/")?.specType == .pseudoRoot)
        #expect(layer.prims.map(\.path) == [
            "/overview_cam",
            "/overview_cam/Head",
            "/TestOver",
            "/TestOverWithoutTypename",
        ])
        let overviewCamera = try #require(layer.spec(at: "/overview_cam"))
        #expect(overviewCamera.specifier == .def)
        #expect(overviewCamera.typeName == "Camera")
        #expect(overviewCamera.fieldNames.contains("properties"))
        let camX = try #require(layer.spec(at: "/overview_cam.camx"))
        #expect(camX.specType == .attribute)
        #expect(camX.typeName == "double")
        #expect(camX.fieldNames.contains("default"))
        let head = try #require(layer.spec(at: "/overview_cam/Head"))
        #expect(head.specifier == .def)
        #expect(head.typeName == "Scope")
        #expect(head.fieldNames.contains("properties"))
        let aspect = try #require(layer.spec(at: "/overview_cam/Head.aspect"))
        #expect(aspect.specType == .attribute)
        #expect(aspect.typeName == "double")
        #expect(aspect.fieldNames.contains("default"))
        let testOver = try #require(layer.spec(at: "/TestOver"))
        #expect(testOver.specifier == .over)
        #expect(testOver.typeName == "MfScope")
        let typelessOver = try #require(layer.spec(at: "/TestOverWithoutTypename"))
        #expect(typelessOver.specifier == .over)
        #expect(typelessOver.typeName == nil)
        #expect(!typelessOver.fieldNames.contains("properties"))
        #expect(layer.primTransforms.keys.sorted() == [
            "/TestOver",
            "/TestOverWithoutTypename",
            "/overview_cam",
            "/overview_cam/Head",
        ])
        #expect(layer.primTransforms.values.allSatisfy { $0 == .identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadFileFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/03_bad_file.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("top-level syntax"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingUnterminatedFixtureThrowsTypedError() throws {
        for fixturePath in [
            "testSdfParsing.testenv/05_bad_file.usda",
            "testSdfParsing.testenv/08_bad_file.usda",
            "testSdfParsing.testenv/09_bad_type.usda",
        ] {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains("unterminated"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadScalarValueFixturesThrowTypedErrors() throws {
        let cases = [
            ("testSdfParsing.testenv/10_bad_value.usda", "bool attribute", "one"),
            ("testSdfParsing.testenv/12_bad_value.usda", "string attribute", "1.23"),
            ("testSdfParsing.testenv/13_bad_value.usda", "int attribute", "\"this"),
            ("testSdfParsing.testenv/14_bad_value.usda", "int attribute", "incorrect"),
        ]
        for (fixturePath, attributeDescription, invalidValue) in cases {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains(attributeDescription))
            #expect(message.contains(invalidValue))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadNestedArrayFixturesThrowTypedErrors() throws {
        for fixturePath in [
            "testSdfParsing.testenv/15_bad_list.usda",
            "testSdfParsing.testenv/16_bad_list.usda",
            "testSdfParsing.testenv/69_bad_list.usda",
            "testSdfParsing.testenv/70_bad_list.usda",
            "testSdfParsing.testenv/179_bad_shaped_attr_dimensions1.usda",
        ] {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains("nested shaped list value"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadPrimDeclarationNewlineFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/22_bad_newline2.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("prim declaration"))
        #expect(message.contains("lines"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsUnexpectedTokenBeforePrimBody() throws {
        let data = Data("""
        #usda 1.0

        def Mesh "Cube" unexpectedToken {
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("prim declaration"))
        #expect(message.contains("unexpected token"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadLayerMetadataNewlineFixturesThrowTypedErrors() throws {
        let cases = [
            ("testSdfParsing.testenv/21_bad_newline1.usda", "layer metadata", "semicolon"),
            ("testSdfParsing.testenv/23_bad_newline3.usda", "layer metadata", "new line"),
        ]

        for (fixturePath, expectedSubject, expectedDetail) in cases {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains(expectedSubject))
            #expect(message.contains(expectedDetail))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadPropertyDeclarationNewlineFixturesThrowTypedErrors() throws {
        let cases = [
            ("testSdfParsing.testenv/24_bad_newline4.usda", "property declaration", "lines"),
            ("testSdfParsing.testenv/26_bad_newline6.usda", "property value", "new line"),
        ]

        for (fixturePath, expectedSubject, expectedDetail) in cases {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains(expectedSubject))
            #expect(message.contains(expectedDetail))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsMissingPropertyName() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            double = 1
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("property declaration"))
        #expect(message.contains("property name"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsInvalidPropertyName() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            double 1bad = 1
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("property name"))
        #expect(message.contains("valid identifier"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsInvalidRelationshipTargetValue() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            rel bad = "notATarget"
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("relationship"))
        #expect(message.contains("invalid target syntax"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsInvalidRelationshipTargetPath() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            rel bad = <bad path>
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("relationship"))
        #expect(message.contains("invalid path characters"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsRelationshipTargetTrailingGarbage() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            rel bad = </Target> garbage
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("relationship"))
        #expect(message.contains("trailing content"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsRelationshipNonePrefixValue() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            rel bad = Nonegarbage
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("relationship"))
        #expect(message.contains("invalid target syntax"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsConnectionNonePrefixValue() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            double output.connect = Nonee
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("relationship"))
        #expect(message.contains("invalid target syntax"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsInvalidNumericScalarValue() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            double radius = nope
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("double attribute"))
        #expect(message.contains("nope"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsScalarValueTrailingGarbage() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            double radius = 1 garbage
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("double attribute"))
        #expect(message.contains("trailing content"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderRejectsArrayNonePrefixValue() throws {
        let data = Data("""
        #usda 1.0

        def Scope "Root" {
            float[] weights = Nonebad
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("float[] attribute"))
        #expect(message.contains("shaped list"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadAttributeVariabilityFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/66_bad_attrVariability.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("property declaration"))
        #expect(message.contains("unexpected token"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingDuplicatePrimFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/90_bad_dupePrim.usda")

        let layerMessage = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }
        let sceneMessage = try usdImportFailureMessage {
            _ = try USDAReader().read(from: data)
        }

        #expect(layerMessage.contains("duplicate prim path"))
        #expect(layerMessage.contains("/A"))
        #expect(sceneMessage.contains("duplicate prim path"))
        #expect(sceneMessage.contains("/A"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingDuplicateRelationshipTargetFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/33_bad_relationship_duplicate_target.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("duplicate target"))
        #expect(message.contains("<Foo/Bar>"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadSpecifierFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/30_bad_specifier.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("unexpected top-level syntax"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadValueTypeFixturesThrowTypedErrors() throws {
        for fixturePath in [
            "testSdfParsing.testenv/91_bad_valueType.usda",
            "testSdfParsing.testenv/96_bad_valueType.usda",
            "testSdfParsing.testenv/97_bad_valueType.usda",
            "testSdfParsing.testenv/98_bad_valueType.usda",
        ] {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains("shaped list value"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingEndTokenFixtureIgnoresTrailingGarbage() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/07_end.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.isEmpty)
        #expect(layer.primTransforms.keys.sorted() == ["/Root"])
        #expect(layer.primTransforms.values.allSatisfy { $0 == .identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingOptionalSemicolonsFixtureReadsSublayersAndPrimTransforms() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/20_optionalsemicolons.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.sublayerAssetPaths == [
            "foo1",
            "foo2",
            "foo3",
            "foo4",
            "foo5",
            "foo6",
            "foo7",
            "foo8",
        ])
        #expect(layer.composition.references.isEmpty)
        #expect(layer.composition.payloads.isEmpty)
        #expect(layer.primTransforms.keys.sorted() == [
            "/Test1",
            "/Test1/Arm",
            "/Test1/Body",
            "/Test1/Head",
            "/Test1/Leg",
            "/Test1/Leg/Thigh",
            "/Test1/Whatever",
        ])
        #expect(layer.primTransforms.values.allSatisfy { $0 == .identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingRelationshipSyntaxFixtureReadsLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/32_relationship_syntax.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path).sorted() == [
            "/customFoo",
            "/customFoo/Scope",
            "/foo",
            "/foo/Scope",
        ])
        let noTargets = try #require(layer.spec(at: "/foo.no_targets_rel"))
        #expect(noTargets.specType == .relationship)
        #expect(!noTargets.fieldNames.contains("targetPaths"))
        let singleTarget = try #require(layer.spec(at: "/foo.single_target_rel"))
        #expect(singleTarget.specType == .relationship)
        #expect(singleTarget.fieldNames.contains("targetPaths"))
        let singleTargetSpec = try #require(layer.spec(at: "/foo.single_target_rel[/foo/Foo]"))
        #expect(singleTargetSpec.specType == .relationshipTarget)
        let complex = try #require(layer.spec(at: "/foo.complex_rel"))
        #expect(complex.specType == .relationship)
        #expect(complex.fieldNames.contains("targetPaths"))
        let multiTargetSpec = try #require(layer.spec(at: "/foo.multi_target_rel[/foo/Bar]"))
        #expect(multiTargetSpec.specType == .relationshipTarget)
        let customNoTargets = try #require(layer.spec(at: "/customFoo.no_targets_rel"))
        #expect(customNoTargets.specType == .relationship)
        #expect(customNoTargets.fieldNames.contains("custom"))
        let relative = try #require(layer.spec(at: "/foo/Scope.rel_relative_path"))
        #expect(relative.specType == .relationship)
        #expect(relative.fieldNames.contains("targetPaths"))
        let relativeTargetSpec = try #require(layer.spec(at: "/foo/Scope.rel_relative_path[..]"))
        #expect(relativeTargetSpec.specType == .relationshipTarget)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingNoEndingNewlineFixtureReadsLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/41_noEndingNewline.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.isEmpty)
        #expect(layer.primTransforms.keys.sorted() == [
            "/overview_cam",
            "/overview_cam/Head",
        ])
        #expect(layer.primTransforms.values.allSatisfy { $0 == .identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingArrayValueSyntaxFixturesReadLayers() throws {
        let testCases: [(fixturePath: String, primPaths: [String])] = [
            ("testSdfParsing.testenv/71_empty_shaped_attrs.usda", ["/mysphere"]),
            ("testSdfParsing.testenv/111_string_arrays.usda", [
                "/string_array_tests",
                "/token_array_tests",
            ]),
        ]

        for testCase in testCases {
            let layer = try USDAReader().readLayer(from: openUSDFixture(testCase.fixturePath))

            #expect(layer.prims.map(\.path).sorted() == testCase.primPaths.sorted())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingAttributePropertySpecsReadLayer() throws {
        let uniformLayer = try USDAReader().readLayer(
            from: openUSDFixture("testSdfParsing.testenv/104_uniformAttributes.usda")
        )
        let foo = try #require(uniformLayer.spec(at: "/bool_tests.foo"))
        #expect(foo.specType == .attribute)
        #expect(foo.typeName == "double")
        #expect(foo.fieldNames.contains("custom"))
        #expect(foo.fieldNames.contains("variability"))
        #expect(foo.fieldNames.contains("default"))
        #expect(foo.fieldNames.contains("connectionPaths"))
        #expect(foo.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            addedItems: ["/bool_tests/Foo/Blah.blah"],
            deletedItems: ["/bool_tests/Foo/Blah.blah"],
            orderedItems: ["/bool_tests/Foo/Blah.blah", "/bool_tests/Foo/Bar.blah"]
        )))
        #expect(uniformLayer.spec(at: "/bool_tests.foo[/bool_tests/Foo/Blah.blah]") == nil)
        #expect(uniformLayer.spec(at: "/bool_tests.foo[/bool_tests/Foo/Bar.blah]") == nil)

        let stringArrayLayer = try USDAReader().readLayer(
            from: openUSDFixture("testSdfParsing.testenv/111_string_arrays.usda")
        )
        let stringTest = try #require(stringArrayLayer.spec(at: "/string_array_tests.test1"))
        #expect(stringTest.specType == .attribute)
        #expect(stringTest.typeName == "string[]")
        #expect(stringTest.fieldNames.contains("custom"))
        #expect(stringTest.fieldNames.contains("default"))
        let tokenTest = try #require(stringArrayLayer.spec(at: "/token_array_tests.test4"))
        #expect(tokenTest.specType == .attribute)
        #expect(tokenTest.typeName == "token[]")
        #expect(tokenTest.fieldNames.contains("default"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingConnectionTargetSpecsReadLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/38_attribute_connections.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path).sorted() == [
            "/attribute_connect_tests",
            "/attribute_rel_connect_tests",
        ])
        let absoluteConnection = try #require(
            layer.spec(at: "/attribute_connect_tests.a0[/attribute_connect_tests/Foo/Bar.blah]")
        )
        #expect(absoluteConnection.specType == .connection)
        let listConnection = try #require(layer.spec(at: "/attribute_connect_tests.a3[/Blah/Blah.boo]"))
        #expect(listConnection.specType == .connection)
        let noneConnectionAttribute = try #require(layer.spec(at: "/attribute_connect_tests.a6"))
        #expect(noneConnectionAttribute.specType == .attribute)
        #expect(noneConnectionAttribute.fieldNames.contains("connectionPaths"))
        let relativeConnection = try #require(layer.spec(at: "/attribute_rel_connect_tests.a0[../Bar.blah]"))
        #expect(relativeConnection.specType == .connection)
        let relativeListConnection = try #require(
            layer.spec(at: "/attribute_rel_connect_tests.a3[../Blah/Blah.boo]")
        )
        #expect(relativeListConnection.specType == .connection)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingRelationshipListOperationsReadLayer() throws {
        let layer = try USDAReader().readLayer(
            from: openUSDFixture("testSdfParsing.testenv/127_varyingRelationship.usda")
        )

        let relationship = try #require(layer.spec(at: "/Sphere.constraintTarget"))
        #expect(relationship.specType == .relationship)
        #expect(relationship.fields["targetPaths"] == .pathListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["/Pivot"],
            addedItems: ["/Pivot3", "/Pivot2"],
            deletedItems: ["/Pivot3"],
            orderedItems: ["/Pivot2", "/Pivot"]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingEmptyTargetListsFixtureReadsLayer() throws {
        let layer = try USDAReader().readLayer(from: openUSDFixture("testSdfParsing.testenv/176_empty_lists.usda"))

        #expect(layer.prims.map(\.path) == ["/Foo"])
        #expect(layer.composition.isEmpty)

        let foo = try #require(layer.spec(at: "/Foo"))
        #expect(foo.specifier == .over)
        #expect(foo.typeName == "Prim")
        #expect(foo.fieldNames.contains("properties"))

        let x1 = try #require(layer.spec(at: "/Foo.x1"))
        #expect(x1.specType == .attribute)
        #expect(x1.typeName == "double")
        #expect(x1.fieldNames.contains("connectionPaths"))
        #expect(layer.spec(at: "/Foo.x1[]") == nil)

        let x5 = try #require(layer.spec(at: "/Foo.x5"))
        #expect(x5.specType == .relationship)
        #expect(x5.fieldNames.contains("targetPaths"))
        #expect(layer.spec(at: "/Foo.x5[]") == nil)
        #expect(layer.specs.allSatisfy { $0.specType != .connection && $0.specType != .relationshipTarget })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadTargetListEditFixturesThrowTypedErrors() throws {
        let cases = [
            ("testSdfParsing.testenv/57_bad_relListEditing.usda", "relationship", "invalid target syntax"),
            ("testSdfParsing.testenv/58_bad_relListEditing.usda", "list-edit", "None"),
            ("testSdfParsing.testenv/59_bad_connectListEditing.usda", "list-edit", "None"),
            ("testSdfParsing.testenv/177_bad_empty_lists.usda", "add list-edit", "empty target list"),
        ]

        for (fixturePath, expectedSubject, expectedDetail) in cases {
            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: openUSDFixture(fixturePath))
            }

            #expect(message.contains(expectedSubject))
            #expect(message.contains(expectedDetail))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingInvalidTypeNameFixtureReadsUnknownPropertyTypes() throws {
        let layer = try USDAReader().readLayer(from: openUSDFixture("testSdfParsing.testenv/178_invalid_typeName.usda"))

        #expect(layer.prims.map(\.path) == ["/foo"])
        let foo = try #require(layer.spec(at: "/foo"))
        #expect(foo.specifier == .def)
        #expect(foo.typeName == "MfScope")
        #expect(foo.fieldNames.contains("properties"))

        let unknownArrayValue = try #require(layer.spec(at: "/foo.a1"))
        #expect(unknownArrayValue.specType == .attribute)
        #expect(unknownArrayValue.typeName == "foobar")
        #expect(unknownArrayValue.fieldNames.contains("typeName"))
        #expect(unknownArrayValue.fieldNames.contains("default"))

        let namespacedType = try #require(layer.spec(at: "/foo.a2"))
        #expect(namespacedType.specType == .attribute)
        #expect(namespacedType.typeName == "Some::EnumValue")
        #expect(namespacedType.fieldNames.contains("typeName"))
        #expect(namespacedType.fieldNames.contains("default"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingNamespacedPropertySpecsReadLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/185_namespaced_properties.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path).sorted() == ["/Prim", "/Prim/Child"])
        let prim = try #require(layer.spec(at: "/Prim"))
        #expect(prim.fieldNames.contains("properties"))
        let child = try #require(layer.spec(at: "/Prim/Child"))
        #expect(!child.fieldNames.contains("properties"))
        #expect(prim.fields["properties"] == .pathListOperation(SdfListOperation(
            orderedItems: [
                "/Prim.bar:baz",
                "/Prim.foo:baz",
                "/Prim.foo:argle",
                "/Prim.bar:argle",
            ]
        )))
        let fooBaz = try #require(layer.spec(at: "/Prim.foo:baz"))
        #expect(fooBaz.specType == .attribute)
        #expect(fooBaz.typeName == "double")
        #expect(fooBaz.fieldNames.contains("custom"))
        #expect(fooBaz.fieldNames.contains("default"))
        let fooArgle = try #require(layer.spec(at: "/Prim.foo:argle"))
        #expect(fooArgle.specType == .attribute)
        #expect(fooArgle.typeName == "double")
        #expect(fooArgle.fieldNames.contains("default"))
        #expect(fooArgle.fieldNames.contains("connectionPaths"))
        let fooArgleConnection = try #require(layer.spec(at: "/Prim.foo:argle[/Prim.foo:baz]"))
        #expect(fooArgleConnection.specType == .connection)
        let fooBargle = try #require(layer.spec(at: "/Prim.foo:bargle"))
        #expect(fooBargle.specType == .attribute)
        #expect(fooBargle.typeName == "double")
        #expect(!fooBargle.fieldNames.contains("default"))
        #expect(fooBargle.fieldNames.contains("connectionPaths"))
        #expect(fooBargle.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            addedItems: ["/Prim.foo:argle"],
            deletedItems: ["/Prim.foo:argle"],
            orderedItems: ["/Prim.foo:argle"]
        )))
        #expect(layer.spec(at: "/Prim.foo:bargle[/Prim.foo:argle]") == nil)
        let barArgle = try #require(layer.spec(at: "/Prim.bar:argle"))
        #expect(barArgle.specType == .attribute)
        #expect(barArgle.fieldNames.contains("default"))
        #expect(barArgle.fieldNames.contains("timeSamples"))
        let argleBargle = try #require(layer.spec(at: "/Prim.argle:bargle"))
        #expect(argleBargle.specType == .relationship)
        #expect(argleBargle.fieldNames.contains("targetPaths"))
        let argleBargleTarget = try #require(layer.spec(at: "/Prim.argle:bargle[/Prim/Child]"))
        #expect(argleBargleTarget.specType == .relationshipTarget)
        let varyingRelationship = try #require(layer.spec(at: "/Prim.a:b:d"))
        #expect(varyingRelationship.specType == .relationship)
        #expect(varyingRelationship.fieldNames.contains("variability"))
        #expect(varyingRelationship.fieldNames.contains("targetPaths"))
        #expect(varyingRelationship.fields["targetPaths"] == .pathListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["/Prim"],
            addedItems: ["/Prim", "/Prim/Child"],
            deletedItems: ["/Prim/Child"],
            orderedItems: ["/Prim", "/Prim/Child"]
        )))
        let varyingTarget = try #require(layer.spec(at: "/Prim.a:b:d[/Prim]"))
        #expect(varyingTarget.specType == .relationshipTarget)
        #expect(layer.spec(at: "/Prim.a:b:d[/Prim/Child]") == nil)
        let emptyRelationship = try #require(layer.spec(at: "/Prim.a:b:e"))
        #expect(emptyRelationship.specType == .relationship)
        #expect(emptyRelationship.fieldNames.contains("variability"))
        #expect(!emptyRelationship.fieldNames.contains("targetPaths"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingWeirdStringContentFixtureSkipsQuotedDelimiters() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/46_weirdStringContent.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.isEmpty)
        #expect(layer.primTransforms.keys.sorted() == ["/foo"])
        #expect(layer.primTransforms.values.allSatisfy { $0 == .identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingAnyTypePrimFixtureReadsLayer() throws {
        let layer = try USDAReader().readLayer(from: openUSDFixture("testSdfParsing.testenv/184_def_AnyType.usda"))

        let expectedPaths = [
            "/DefWithAnyType",
            "/DefWithEmptyType",
            "/OverWithAnyType",
            "/OverWithEmptyType",
            "/ClassWithAnyType",
            "/ClassWithEmptyType",
        ]
        #expect(layer.prims.map(\.path) == expectedPaths)

        let defWithAnyType = try #require(layer.spec(at: "/DefWithAnyType"))
        #expect(defWithAnyType.specifier == .def)
        #expect(defWithAnyType.typeName == "__AnyType__")
        let defWithEmptyType = try #require(layer.spec(at: "/DefWithEmptyType"))
        #expect(defWithEmptyType.specifier == .def)
        #expect(defWithEmptyType.typeName == nil)
        let overWithAnyType = try #require(layer.spec(at: "/OverWithAnyType"))
        #expect(overWithAnyType.specifier == .over)
        #expect(overWithAnyType.typeName == "__AnyType__")
        let classWithEmptyType = try #require(layer.spec(at: "/ClassWithEmptyType"))
        #expect(classWithEmptyType.specifier == .class)
        #expect(classWithEmptyType.typeName == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingOpaqueAttributesFixtureReadsLayer() throws {
        let layer = try USDAReader().readLayer(from: openUSDFixture("testSdfParsing.testenv/210_opaque_attributes.usda"))

        #expect(layer.prims.map(\.path) == ["/MyScope"])
        let myScope = try #require(layer.spec(at: "/MyScope"))
        #expect(myScope.specifier == .def)
        #expect(myScope.typeName == "Scope")
        #expect(myScope.fieldNames.contains("properties"))

        let opaqueAttr = try #require(layer.spec(at: "/MyScope.OpaqueAttr"))
        #expect(opaqueAttr.specType == .attribute)
        #expect(opaqueAttr.typeName == "opaque")
        #expect(opaqueAttr.fieldNames.contains("custom"))
        #expect(opaqueAttr.fieldNames.contains("connectionPaths"))
        #expect(!opaqueAttr.fieldNames.contains("default"))
        let connection = try #require(layer.spec(at: "/MyScope.OpaqueAttr[.OtherAttr]"))
        #expect(connection.specType == .connection)

        let otherAttr = try #require(layer.spec(at: "/MyScope.OtherAttr"))
        #expect(otherAttr.specType == .attribute)
        #expect(otherAttr.typeName == "group")
        #expect(otherAttr.fieldNames.contains("custom"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingAuthoredOpaqueAttributeFixtureThrowsTypedError() throws {
        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(
                from: openUSDFixture("testSdfParsing.testenv/211_bad_authored_opaque_attributes.usda")
            )
        }

        #expect(message.contains("opaque attribute"))
        #expect(message.contains("default value"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingUTF8IdentifiersFixtureReadsDefaultPrimAndTransforms() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/217_utf8_identifiers.usda")

        let layer = try USDAReader().readLayer(from: data)
        let rootPath = "/_Süßigkeiten"
        let childPath = "\(rootPath)/ⅈ573"
        let rootTransform = try #require(layer.primTransforms[rootPath])
        let childTransform = try #require(layer.primTransforms[childPath])
        let origin = USDPoint3D(x: 0, y: 0, z: 0)
        let translatedOrigin = USDPoint3D(x: 4, y: 5, z: 6)

        #expect(layer.defaultPrim == "_Süßigkeiten")
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.composition.isEmpty)
        #expect(layer.primTransforms.keys.sorted() == [rootPath, childPath])
        #expect(try rootTransform.transform(origin) == translatedOrigin)
        #expect(try childTransform.transform(origin) == translatedOrigin)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingUTF8BadIdentifierFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/218_utf8_bad_identifier.usda")

        do {
            _ = try USDAReader().readLayer(from: data)
            Issue.record("Expected invalid UTF-8 prim identifier to fail.")
        } catch USDError.invalidData(let message) {
            #expect(message.contains("valid identifier"))
            #expect(message.contains("㤼01৪∫"))
        } catch {
            Issue.record("Expected USDError.invalidData, got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingUTF8BadTypeNameFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/219_utf8_bad_type_name.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("property type name"))
        #expect(message.contains("valid identifier"))
        #expect(message.contains("㤼01৪∫"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadPrimNameFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/61_bad_primName.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("prim name"))
        #expect(message.contains("valid identifier"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingHiddenMetadataFixtureReadsLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/93_hidden.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path).sorted() == ["/RefComp", "/RefComp2", "/RefComp3"])
        #expect(layer.spec(at: "/")?.fields["framesPerSecond"] == .authored("24"))
        #expect(layer.spec(at: "/RefComp2")?.fields["hidden"] == .authored("true"))
        #expect(layer.spec(at: "/RefComp2")?.fields["permission"] == .authored("private"))
        #expect(layer.spec(at: "/RefComp2.attr")?.fields["hidden"] == .authored("false"))
        #expect(layer.spec(at: "/RefComp2.myRel")?.fields["permission"] == .authored("private"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRoundTripsAuthoredLayerFields() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 0.01
            upAxis = "Z"
            customLayerData = {
                string owner = "tools"
            }
        )

        def Xform "Root" (
            displayName = "Hero Root"
            variants = {
                string modelingVariant = "high"
            }
        )
        {
            token zeta = "last"

            double driven.connect = </Source.value>

            point3f[] points.timeSamples = {
                1: [(0, 0, 0)],
                2: [(1, 0, 0)]
            }

            add rel extraTargets = [</TargetA>, </TargetB>]

            delete rel extraTargets = [</TargetC>]

            add double linked.connect = [</Source.extra>]

            double compound = 1

            double compound.connect = </Source.compound>

            double compound.timeSamples = {
                1: 1,
                2: 2
            }

            custom uniform double width (
                displayName = "Width"
            ) = 2.5

            variantSet "modelingVariant" = {
                "high" {
                    def Scope "HighGeom"
                    {
                    }
                }
            }
        }
        """.utf8)
        let layer = try USDAReader().readLayer(from: data)

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)

        #expect(written.contains("customLayerData = {"))
        #expect(written.contains("variants = {"))
        #expect(written.contains("variantSet \"modelingVariant\""))
        #expect(written.contains("custom uniform double width"))
        let zetaRange = try #require(written.range(of: "token zeta"))
        let widthRange = try #require(written.range(of: "custom uniform double width"))
        #expect(zetaRange.lowerBound < widthRange.lowerBound)
        #expect(written.contains("double driven.connect = </Source.value>"))
        #expect(written.contains("point3f[] points.timeSamples = {"))
        #expect(written.contains("add rel extraTargets = [</TargetA>, </TargetB>]"))
        #expect(written.contains("delete rel extraTargets = [</TargetC>]"))
        #expect(written.contains("add double linked.connect = [</Source.extra>]"))
        #expect(written.contains("double compound = 1"))
        #expect(written.contains("double compound.connect = </Source.compound>"))
        #expect(written.contains("double compound.timeSamples = {"))
        #expect(roundTripped.defaultPrim == "Root")
        #expect(roundTripped.upAxis == .z)
        #expect(roundTripped.spec(at: "/")?.fields["customLayerData"] == .dictionary([
            "owner": .string("tools"),
        ]))
        #expect(roundTripped.spec(at: "/Root")?.fields["displayName"] == .authored("\"Hero Root\""))
        #expect(roundTripped.spec(at: "/Root")?.fields["variants"] == .dictionary([
            "modelingVariant": .string("high"),
        ]))
        #expect(roundTripped.spec(at: "/Root{modelingVariant}")?.specType == .variantSet)
        #expect(roundTripped.spec(at: "/Root{modelingVariant=high}")?.specType == .variant)
        #expect(roundTripped.spec(at: "/Root{modelingVariant=high}")?.fields["body"] == nil)
        #expect(roundTripped.spec(at: "/Root{modelingVariant=high}/HighGeom")?.specType == .prim)
        #expect(roundTripped.spec(at: "/Root")?.fields["properties"] == .authored(
            "/Root.zeta, /Root.driven, /Root.driven[/Source.value], /Root.points, /Root.extraTargets, /Root.linked, /Root.compound, /Root.compound[/Source.compound], /Root.width"
        ))
        #expect(roundTripped.spec(at: "/Root.zeta")?.fields["default"] == .authored("\"last\""))
        #expect(roundTripped.spec(at: "/Root.driven")?.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["/Source.value"]
        )))
        #expect(roundTripped.spec(at: "/Root.points")?.fields["timeSamples"] == .authored(
            "{\n        1: [(0, 0, 0)],\n        2: [(1, 0, 0)]\n    }"
        ))
        #expect(roundTripped.spec(at: "/Root.extraTargets")?.fields["targetPaths"] == .pathListOperation(SdfListOperation(
            addedItems: ["/TargetA", "/TargetB"],
            deletedItems: ["/TargetC"]
        )))
        #expect(roundTripped.spec(at: "/Root.linked")?.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            addedItems: ["/Source.extra"]
        )))
        #expect(roundTripped.spec(at: "/Root.linked[/Source.extra]") == nil)
        #expect(roundTripped.spec(at: "/Root.compound")?.fields["default"] == .authored("1"))
        #expect(roundTripped.spec(at: "/Root.compound")?.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["/Source.compound"]
        )))
        #expect(roundTripped.spec(at: "/Root.compound")?.fields["timeSamples"] == .authored(
            "{\n        1: 1,\n        2: 2\n    }"
        ))
        #expect(roundTripped.spec(at: "/Root.width")?.fields["default"] == .authored("2.5"))
        #expect(roundTripped.spec(at: "/Root.width")?.fields["displayName"] == .authored("\"Width\""))
        #expect(roundTripped.spec(at: "/Root.width")?.fields["variability"] == .authored("uniform"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterSynthesizesAllPropertyValueFieldsWithoutRawStatements() throws {
        let layer = USDALayer(specs: [
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform"
            ),
            USDLayerSpec(
                path: "/Root.multi",
                specType: .attribute,
                typeName: "double",
                fieldNames: ["typeName", "default", "connectionPaths", "timeSamples"],
                fields: [
                    "typeName": .authored("double"),
                    "default": .authored("1"),
                    "connectionPaths": .pathListOperation(SdfListOperation(
                        isExplicit: true,
                        explicitItems: ["/Source.output"]
                    )),
                    "timeSamples": .authored("""
                    {
                        1: 1,
                        2: 2
                    }
                    """),
                ]
            ),
            USDLayerSpec(
                path: "/Root.targets",
                specType: .relationship,
                fieldNames: ["targetPaths"],
                fields: [
                    "targetPaths": .pathListOperation(SdfListOperation(addedItems: ["/A", "/B"])),
                ]
            ),
        ])

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)

        #expect(written.contains("double multi = 1"))
        #expect(written.contains("double multi.connect = </Source.output>"))
        #expect(written.contains("double multi.timeSamples = {"))
        #expect(written.contains("add rel targets = [</A>, </B>]"))
        #expect(roundTripped.spec(at: "/Root.multi")?.fields["default"] == .authored("1"))
        #expect(roundTripped.spec(at: "/Root.multi")?.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["/Source.output"]
        )))
        #expect(roundTripped.spec(at: "/Root.multi")?.fields["timeSamples"] != nil)
        #expect(roundTripped.spec(at: "/Root.targets")?.fields["targetPaths"] == .pathListOperation(SdfListOperation(
            addedItems: ["/A", "/B"]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterPropertyOrderExplicitListEmitsReorderSyntax() throws {
        let layer = USDALayer(specs: [
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["properties"],
                fields: [
                    "properties": .pathListOperation(SdfListOperation(
                        isExplicit: true,
                        explicitItems: ["/Root.b", "/Root.a"]
                    )),
                ]
            ),
            USDLayerSpec(
                path: "/Root.a",
                specType: .attribute,
                typeName: "double",
                fields: ["default": .authored("1")]
            ),
            USDLayerSpec(
                path: "/Root.b",
                specType: .attribute,
                typeName: "double",
                fields: ["default": .authored("2")]
            ),
        ])

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)

        #expect(written.contains("reorder properties = [\"b\", \"a\"]"))
        #expect(roundTripped.spec(at: "/Root")?.fields["properties"] == .pathListOperation(SdfListOperation(
            orderedItems: ["/Root.b", "/Root.a"]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterPreservesRawVariantSetBodyWhenVariantsAreNotMaterialized() throws {
        let layer = USDALayer(specs: [
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform"
            ),
            USDLayerSpec(
                path: "/Root{modelingVariant}",
                specType: .variantSet,
                fields: [
                    "body": .authored("""
                    "low" {
                        def Scope "Low"
                        {
                        }
                    }
                    """),
                ]
            ),
        ])

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)

        #expect(written.contains("variantSet \"modelingVariant\""))
        #expect(written.contains("\"low\" {"))
        #expect(written.contains("def Scope \"Low\""))
        #expect(roundTripped.spec(at: "/Root{modelingVariant=low}")?.fields["body"] == nil)
        #expect(roundTripped.spec(at: "/Root{modelingVariant=low}/Low")?.specType == .prim)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderMaterializesStructuredVariantBodySpecs() throws {
        let layer = try SdfLayer.importUSDA(from: Data("""
        #usda 1.0

        def Xform "Root"
        {
            variantSet "modelingVariant" = {
                "high" {
                    reorder properties = ["width"]
                    double width = 2.5
                    def Scope "Geom"
                    {
                        token purpose = "render"
                    }
                    variantSet "lod" = {
                        "low" {
                            token detail = "proxy"
                        }
                    }
                }
            }
        }
        """.utf8))
        let variantPath = try SdfPath("/Root{modelingVariant=high}")
        let widthPath = try SdfPath("/Root{modelingVariant=high}.width")
        let geomPath = try SdfPath("/Root{modelingVariant=high}/Geom")
        let purposePath = try SdfPath("/Root{modelingVariant=high}/Geom.purpose")
        let lodVariantSetPath = try SdfPath("/Root{modelingVariant=high}{lod}")
        let lodVariantPath = try SdfPath("/Root{modelingVariant=high}{lod=low}")
        let detailPath = try SdfPath("/Root{modelingVariant=high}{lod=low}.detail")

        #expect(layer.spec(at: variantPath)?.fields["body"] == nil)
        #expect(layer.spec(at: variantPath)?.fields["properties"] == .pathListOperation(SdfListOperation(
            orderedItems: [widthPath]
        )))
        #expect(layer.spec(at: widthPath)?.fields["default"] == .authored("2.5"))
        #expect(layer.spec(at: geomPath)?.specType == .prim)
        #expect(layer.spec(at: purposePath)?.fields["default"] == .authored("\"render\""))
        #expect(layer.spec(at: lodVariantSetPath)?.specType == .variantSet)
        #expect(layer.spec(at: lodVariantPath)?.fields["body"] == nil)
        #expect(layer.spec(at: detailPath)?.fields["default"] == .authored("\"proxy\""))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderPreservesRawVariantBodyWhenDirectStatementsAreUnsupported() throws {
        let layer = try USDAReader().readLayer(from: Data("""
        #usda 1.0

        def Xform "Root"
        {
            variantSet "modelingVariant" = {
                "high" {
                    unknownStatement = {
                        string owner = "raw"
                    }
                    def Scope "Known"
                    {
                    }
                }
            }
        }
        """.utf8))
        let bodyField = try #require(layer.spec(at: "/Root{modelingVariant=high}")?.fields["body"])

        #expect(layer.spec(at: "/Root{modelingVariant=high}/Known") == nil)
        if case .authored(let body) = bodyField {
            #expect(body.contains("unknownStatement = {"))
            #expect(body.contains("def Scope \"Known\""))
        } else {
            Issue.record("Expected unsupported variant body to be preserved as authored text.")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterWritesStructuredVariantSpecsWithoutRawBody() throws {
        let variantPath = try SdfPath("/Root{modelingVariant=high}")
        let widthPath = try SdfPath("/Root{modelingVariant=high}.width")
        let layer = try SdfLayer(
            defaultPrim: "Root",
            specs: [
                SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
                SdfSpec(path: "/Root", specType: .prim, specifier: .def, typeName: "Xform"),
                SdfSpec(path: "/Root{modelingVariant}", specType: .variantSet),
                SdfSpec(
                    path: variantPath,
                    specType: .variant,
                    fieldNames: ["name", "properties"],
                    fields: [
                        "name": .authored("\"high\""),
                        "properties": .pathListOperation(SdfListOperation(orderedItems: [widthPath])),
                    ]
                ),
                SdfSpec(
                    path: widthPath,
                    specType: .attribute,
                    typeName: "double",
                    fields: [
                        "default": .authored("2.5"),
                        "typeName": .authored("double"),
                    ]
                ),
                SdfSpec(path: "/Root{modelingVariant=high}/Geom", specType: .prim, specifier: .def, typeName: "Scope"),
                SdfSpec(
                    path: "/Root{modelingVariant=high}/Geom.purpose",
                    specType: .attribute,
                    typeName: "token",
                    fields: [
                        "default": .authored("\"render\""),
                        "typeName": .authored("token"),
                    ]
                ),
            ]
        )

        let written = try layer.exportUSDA()
        let roundTripped = try USDAReader().readLayer(from: written)

        #expect(written.contains("variantSet \"modelingVariant\""))
        #expect(written.contains("\"high\" {"))
        #expect(written.contains("reorder properties = [\"width\"]"))
        #expect(written.contains("double width = 2.5"))
        #expect(written.contains("def Scope \"Geom\""))
        #expect(written.contains("token purpose = \"render\""))
        #expect(roundTripped.spec(at: variantPath.rawValue)?.fields["body"] == nil)
        #expect(roundTripped.spec(at: variantPath.rawValue)?.fields["properties"] == .pathListOperation(SdfListOperation(
            orderedItems: [widthPath.rawValue]
        )))
        #expect(roundTripped.spec(at: widthPath.rawValue)?.fields["default"] == .authored("2.5"))
        #expect(roundTripped.spec(at: "/Root{modelingVariant=high}/Geom")?.specType == .prim)
        #expect(roundTripped.spec(at: "/Root{modelingVariant=high}/Geom.purpose")?.fields["default"] == .authored("\"render\""))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRejectsVariantRawBodyMixedWithStructuredSpecs() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(path: "/Root", specType: .prim, specifier: .def, typeName: "Xform"),
            SdfSpec(path: "/Root{modelingVariant}", specType: .variantSet),
            SdfSpec(
                path: "/Root{modelingVariant=high}",
                specType: .variant,
                fieldNames: ["name", "body"],
                fields: [
                    "name": .authored("\"high\""),
                    "body": .authored("""
                    def Scope "RawGeom"
                    {
                    }
                    """),
                ]
            ),
            SdfSpec(path: "/Root{modelingVariant=high}/StructuredGeom", specType: .prim, specifier: .def),
        ])

        #expect(throws: USDError.self) {
            _ = try layer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRejectsVariantSetRawBodyMixedWithStructuredVariants() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(path: "/Root", specType: .prim, specifier: .def, typeName: "Xform"),
            SdfSpec(
                path: "/Root{modelingVariant}",
                specType: .variantSet,
                fields: [
                    "body": .authored("""
                    "low" {
                        def Scope "Low"
                        {
                        }
                    }
                    """),
                ]
            ),
            SdfSpec(path: "/Root{modelingVariant=high}", specType: .variant),
        ])

        #expect(throws: USDError.self) {
            _ = try layer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRejectsUnsupportedVariantSetFields() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(path: "/Root", specType: .prim, specifier: .def, typeName: "Xform"),
            SdfSpec(
                path: "/Root{modelingVariant}",
                specType: .variantSet,
                fields: [
                    "displayName": .string("Modeling"),
                ]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try layer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRejectsUnknownPrimSpecifier() throws {
        let layer = USDALayer(specs: [
            USDLayerSpec(path: "/Root", specType: .prim, specifier: .unknown(255), typeName: "Xform"),
        ])

        #expect(throws: USDError.self) {
            _ = try USDAWriter().string(for: layer)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRejectsDuplicatePropertySpecs() throws {
        let layer = USDALayer(specs: [
            USDLayerSpec(path: "/Root", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(
                path: "/Root.value",
                specType: .attribute,
                typeName: "double",
                fields: ["default": .authored("1")]
            ),
            USDLayerSpec(
                path: "/Root.value",
                specType: .attribute,
                typeName: "double",
                fields: ["default": .authored("2")]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try USDAWriter().string(for: layer)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRejectsOrphanAndUnsupportedLayerSpecs() throws {
        let orphanPropertyLayer = USDALayer(specs: [
            USDLayerSpec(
                path: "/Missing.value",
                specType: .attribute,
                typeName: "double",
                fields: ["default": .authored("1")]
            ),
        ])
        let orphanVariantLayer = USDALayer(specs: [
            USDLayerSpec(path: "/Root{modelingVariant=high}", specType: .variant),
        ])
        let unsupportedTargetMetadataLayer = USDALayer(specs: [
            USDLayerSpec(path: "/Root", specType: .prim, specifier: .def),
            USDLayerSpec(
                path: "/Root.target",
                specType: .relationship,
                fieldNames: ["targetPaths"],
                fields: [
                    "targetPaths": .pathListOperation(SdfListOperation(isExplicit: true, explicitItems: ["/Target"])),
                ]
            ),
            USDLayerSpec(
                path: "/Root.target[/Target]",
                specType: .relationshipTarget,
                fieldNames: ["displayName"],
                fields: ["displayName": .authored("\"Target\"")]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try USDAWriter().string(for: orphanPropertyLayer)
        }
        #expect(throws: USDError.self) {
            _ = try USDAWriter().string(for: orphanVariantLayer)
        }
        #expect(throws: USDError.self) {
            _ = try USDAWriter().string(for: unsupportedTargetMetadataLayer)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfPathClassifiesSceneDescriptionPaths() throws {
        let root = SdfPath.absoluteRoot
        let world = try SdfPath("/World")
        let geom = try world.appendingChild("Geom")
        let points = try geom.appendingProperty("points")
        let binding = try world.appendingProperty("look:binding")
        let target = try SdfPath("/World.look:binding[/Looks/Mat.preview]")
        let variantSet = try SdfPath("/World{modelingVariant}")
        let variantSelection = try SdfPath("/World{modelingVariant=high}")
        let chainedVariantSet = try SdfPath("/World{modelingVariant=high}{lod}")
        let chainedVariantSelection = try SdfPath("/World{modelingVariant=high}{lod=low}")
        let variantPrim = try SdfPath("/World{modelingVariant=high}/Geom")
        let targetPrim = try SdfPath("/Looks/Mat.preview")
        let relativePrim = try SdfPath("World")
        let relativeTargetPath = try SdfPath("/World.rel[Target]")
        let relativeTarget = try SdfPath("Target")

        #expect(root.kind == .pseudoRoot)
        #expect(root.parentPath == nil)
        #expect(world.kind == .prim)
        #expect(world.parentPath == root)
        #expect(geom.rawValue == "/World/Geom")
        #expect(points.kind == .property)
        #expect(points.primPath == geom)
        #expect(points.propertyName == "points")
        #expect(binding.propertyName == "look:binding")
        #expect(target.kind == .propertyTarget)
        #expect(target.propertyPath == binding)
        #expect(target.targetPath == targetPrim)
        #expect(relativePrim.isRelative)
        #expect(relativeTargetPath.targetPath == relativeTarget)
        #expect(variantSet.kind == .variantSet)
        #expect(variantSet.parentPath == world)
        #expect(chainedVariantSet.kind == .variantSet)
        #expect(chainedVariantSet.parentPath == variantSelection)
        #expect(chainedVariantSelection.kind == .variantSelection)
        #expect(variantPrim.kind == .prim)
        #expect(variantPrim.containsVariantSelection)
        #expect(variantPrim.parentPath == variantSelection)

        for invalidPath in ["", "/World/", "/World..bad", "/World{variant}/Geom"] {
            #expect(throws: USDError.self) {
                _ = try SdfPath(invalidPath)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfSpecFieldsPreserveOrderAndTypedListOperations() throws {
        let sourcePath = try SdfPath("/Source.output")
        var spec = try SdfSpec(path: "/Root.input", specType: .attribute, typeName: "double")
        spec.setField(.authored("double"), for: "typeName")
        spec.setField(.authored("1"), for: "default")
        spec.setField(.pathListOperation(SdfListOperation(isExplicit: true, explicitItems: [sourcePath])), for: "connectionPaths")

        let usdSpec = spec.toUSDLayerSpec()
        let restored = try SdfSpec(layerSpec: usdSpec)

        #expect(spec.listFields() == ["typeName", "default", "connectionPaths"])
        #expect(spec.hasField(named: "default"))
        #expect(usdSpec.fields["connectionPaths"] == .pathListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["/Source.output"]
        )))
        #expect(restored.field(named: "connectionPaths")?.pathListOperation?.explicitItems == [sourcePath])

        spec.clearField(named: "default")

        #expect(!spec.hasField(named: "default"))
        #expect(spec.listFields() == ["typeName", "connectionPaths"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdListOperationEffectiveItemsApplyListEdits() {
        let operation = SdfListOperation(
            isExplicit: true,
            explicitItems: ["A", "B", "B"],
            addedItems: ["D", "C"],
            prependedItems: ["C", "A"],
            appendedItems: ["A", "E"],
            deletedItems: ["B"],
            orderedItems: ["E", "C", "Missing"]
        )

        #expect(operation.effectiveItems == ["A", "B"])
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportRejectsNonRoundTrippableMetadataValues() throws {
        let listOperationLayer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fields: [
                    "labels": .stringListOperation(SdfListOperation(prependedItems: ["hero"])),
                ]
            ),
        ])
        let arbitraryReferenceFieldLayer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fields: [
                    "customReferences": .referenceListOperation(SdfListOperation(
                        isExplicit: true,
                        explicitItems: [
                            SdfReference(assetPath: "asset.usda"),
                        ]
                    )),
                ]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try listOperationLayer.exportUSDA()
        }
        #expect(throws: USDError.self) {
            _ = try arbitraryReferenceFieldLayer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportsStructuredDictionaryMetadataWithoutLoss() throws {
        let dictionaryValue = SdfFieldValue.dictionary([
            "asset": .assetPath("textures/@albedo@.png"),
            "nested value": .dictionary([
                "enabled": .bool(true),
                "origin": .point2(USDPoint2D(x: 0.25, y: 0.75)),
                "samples": .doubleArray([1.25, 2]),
                "startTime": .timeCode(24),
            ]),
            "owner": .string("tools"),
            "stValues": .point2Array([
                USDPoint2D(x: 0, y: 0),
                USDPoint2D(x: 1, y: 1),
            ]),
            "tags": .tokenArray(["hero", "render"]),
        ])
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["specifier", "typeName", "customData"],
                fields: [
                    "specifier": .specifier(.def),
                    "typeName": .token("Xform"),
                    "customData": dictionaryValue,
                ]
            ),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("customData = {"))
        #expect(written.contains("asset asset = @@@textures/@albedo@.png@@@"))
        #expect(written.contains("dictionary \"nested value\" = {"))
        #expect(written.contains("double2 origin = (0.25, 0.75)"))
        #expect(written.contains("double2[] stValues = [(0.0, 0.0), (1.0, 1.0)]"))
        #expect(written.contains("timecode startTime = 24.0"))
        #expect(roundTripped.field(named: "customData", at: try SdfPath("/Root")) == dictionaryValue)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderMaterializesDictionaryPoint2Aliases() throws {
        let layer = try SdfLayer.importUSDA(from: """
        #usda 1.0

        def Xform "Root" (
            customData = {
                float2 st = (0.5, 1)
                texCoord2f[] uvSet = [(0, 0), (1, 1)]
            }
        )
        {
        }
        """)

        #expect(layer.field(named: "customData", at: try SdfPath("/Root")) == .dictionary([
            "st": .point2(USDPoint2D(x: 0.5, y: 1)),
            "uvSet": .point2Array([
                USDPoint2D(x: 0, y: 0),
                USDPoint2D(x: 1, y: 1),
            ]),
        ]))
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportsStringSubstitutionMetadataWithoutLoss() throws {
        let substitutionFields: [String: SdfFieldValue] = [
            "prefixSubstitutions": .dictionary([
                "$Left": .string("Right"),
                "Left": .string("Right"),
            ]),
            "suffixSubstitutions": .dictionary([
                "$NUM": .string("1"),
            ]),
        ]
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/RightLeg",
                specType: .prim,
                specifier: .def,
                typeName: "MfScope",
                fieldNames: ["specifier", "typeName", "prefixSubstitutions", "suffixSubstitutions"],
                fields: [
                    "specifier": .specifier(.def),
                    "typeName": .token("MfScope"),
                ].merging(substitutionFields) { _, new in new }
            ),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("prefixSubstitutions = {"))
        #expect(written.contains("\"$Left\": \"Right\","))
        #expect(written.contains("\"Left\": \"Right\","))
        #expect(written.contains("suffixSubstitutions = {"))
        #expect(written.contains("\"$NUM\": \"1\","))
        #expect(roundTripped.field(named: "prefixSubstitutions", at: try SdfPath("/RightLeg")) == substitutionFields["prefixSubstitutions"])
        #expect(roundTripped.field(named: "suffixSubstitutions", at: try SdfPath("/RightLeg")) == substitutionFields["suffixSubstitutions"])
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportRejectsInvalidStringSubstitutionMetadata() throws {
        let nonStringValueLayer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fields: [
                    "prefixSubstitutions": .dictionary([
                        "$Left": .token("Right"),
                    ]),
                ]
            ),
        ])
        let emptyKeyLayer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fields: [
                    "suffixSubstitutions": .dictionary([
                        "": .string("1"),
                    ]),
                ]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try nonStringValueLayer.exportUSDA()
        }
        #expect(throws: USDError.self) {
            _ = try emptyKeyLayer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportsKnownTokenMetadataListOperationsWithoutLoss() throws {
        let operation = SdfListOperation(
            isExplicit: true,
            explicitItems: ["CollectionAPI"],
            prependedItems: ["PhysicsAPI"],
            appendedItems: ["MaterialBindingAPI"],
            deletedItems: ["OldAPI"],
            orderedItems: ["PhysicsAPI", "CollectionAPI"]
        )
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["specifier", "typeName", "apiSchemas"],
                fields: [
                    "specifier": .specifier(.def),
                    "typeName": .token("Xform"),
                    "apiSchemas": .tokenListOperation(operation),
                ]
            ),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("apiSchemas = \"CollectionAPI\""))
        #expect(written.contains("prepend apiSchemas = \"PhysicsAPI\""))
        #expect(written.contains("append apiSchemas = \"MaterialBindingAPI\""))
        #expect(written.contains("delete apiSchemas = \"OldAPI\""))
        #expect(written.contains("reorder apiSchemas = [\"PhysicsAPI\", \"CollectionAPI\"]"))
        #expect(roundTripped.field(named: "apiSchemas", at: try SdfPath("/Root")) == .tokenListOperation(operation))
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportsVariantSetNamesMetadataListOperationsWithoutLoss() throws {
        let rootPath = try SdfPath("/Root")
        let operation = SdfListOperation(
            isExplicit: true,
            explicitItems: ["modelingVariant", "lookVariant"],
            addedItems: ["renderVariant"],
            prependedItems: ["lod"],
            deletedItems: ["oldVariant"],
            orderedItems: ["lod", "modelingVariant"]
        )
        let layer = SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: rootPath,
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["specifier", "typeName", "variantSetNames"],
                fields: [
                    "specifier": .specifier(.def),
                    "typeName": .token("Xform"),
                    "variantSetNames": .stringListOperation(operation),
                ]
            ),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("variantSets = [\"modelingVariant\", \"lookVariant\"]"))
        #expect(written.contains("add variantSets = \"renderVariant\""))
        #expect(written.contains("prepend variantSets = \"lod\""))
        #expect(written.contains("delete variantSets = \"oldVariant\""))
        #expect(written.contains("reorder variantSets = [\"lod\", \"modelingVariant\"]"))
        #expect(roundTripped.field(named: "variantSetNames", at: rootPath) == .stringListOperation(operation))
        #expect(roundTripped.spec(at: try SdfPath("/Root{modelingVariant}"))?.specType == .variantSet)
        #expect(roundTripped.spec(at: try SdfPath("/Root{lookVariant}"))?.specType == .variantSet)
        #expect(roundTripped.spec(at: try SdfPath("/Root{renderVariant}"))?.specType == .variantSet)
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportRejectsInvalidVariantSetNamesMetadata() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fields: [
                    "variantSetNames": .stringListOperation(SdfListOperation(
                        isExplicit: true,
                        explicitItems: ["bad name"]
                    )),
                ]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try layer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportsInheritsAndSpecializesPathListOperationsWithoutLoss() throws {
        let rootPath = try SdfPath("/Root")
        let rigPath = try SdfPath("/Rig")
        let mixinPath = try SdfPath("/Mixin")
        let oldRigPath = try SdfPath("/OldRig")
        let specializedPath = try SdfPath("/Specialized")
        let inheritOperation = SdfListOperation(
            isExplicit: true,
            explicitItems: [rigPath],
            prependedItems: [mixinPath],
            deletedItems: [oldRigPath],
            orderedItems: [mixinPath, rigPath]
        )
        let specializesOperation = SdfListOperation(appendedItems: [specializedPath])
        let layer = SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: rootPath,
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["specifier", "typeName", "inheritPaths", "specializes"],
                fields: [
                    "specifier": .specifier(.def),
                    "typeName": .token("Xform"),
                    "inheritPaths": .pathListOperation(inheritOperation),
                    "specializes": .pathListOperation(specializesOperation),
                ]
            ),
            SdfSpec(path: rigPath, specType: .prim, specifier: .class),
            SdfSpec(path: mixinPath, specType: .prim, specifier: .class),
            SdfSpec(path: oldRigPath, specType: .prim, specifier: .class),
            SdfSpec(path: specializedPath, specType: .prim, specifier: .class),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("inherits = </Rig>"))
        #expect(written.contains("delete inherits = </OldRig>"))
        #expect(written.contains("prepend inherits = </Mixin>"))
        #expect(written.contains("reorder inherits = [</Mixin>, </Rig>]"))
        #expect(written.contains("append specializes = </Specialized>"))
        #expect(roundTripped.field(named: "inheritPaths", at: rootPath) == .pathListOperation(inheritOperation))
        #expect(roundTripped.field(named: "specializes", at: rootPath) == .pathListOperation(specializesOperation))
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportWritesTokenEnumsAndEscapedAssetPaths() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["specifier", "typeName", "permission", "assetPath", "references"],
                fields: [
                    "specifier": .specifier(.def),
                    "typeName": .token("Xform"),
                    "permission": .permission(.privateAccess),
                    "assetPath": .assetPath("textures/@albedo@.png"),
                    "references": .referenceListOperation(SdfListOperation(
                        isExplicit: true,
                        explicitItems: [
                            SdfReference(assetPath: "assets/@hero@.usda", primPath: try SdfPath("/Hero")),
                        ]
                    )),
                ]
            ),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("permission = private"))
        #expect(!written.contains("permission = \"private\""))
        #expect(written.contains("@@@textures/@albedo@.png@@@"))
        #expect(written.contains("@@@assets/@hero@.usda@@@</Hero>"))
        #expect(roundTripped.field(named: "permission", at: try SdfPath("/Root")) == .authored("private"))
        #expect(roundTripped.field(named: "references", at: try SdfPath("/Root")) == .referenceListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: [
                SdfReference(assetPath: "assets/@hero@.usda", primPath: try SdfPath("/Hero")),
            ]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdPluginRegistryParsesPlugInfoAndSchemaRegistryBuildsDefinitions() throws {
        let plugInfo = Data("""
        {
            # Hash comments are accepted by OpenUSD plugInfo files.
            "Plugins": [
                {
                    "Type": "resource",
                    "Name": "ExampleSchemas",
                    "Root": "schemas",
                    "ResourcePath": "resources",
                    "Info": {
                        "Types": {
                            "Hair": {
                                "schemaKind": "concreteTyped",
                                "fallbackPrimTypes": ["Xform"],
                                "propertyNames": ["points", "widths"],
                                "fallbackFields": {
                                    "purpose": "render"
                                }
                            },
                            "PhysicsAPI": {
                                "apiSchemaType": "singleApply",
                                "propertyNames": ["physics:mass"],
                                "fallbackFields": {
                                    "physics:mass": 1.0
                                }
                            }
                        }
                    }
                }
            ]
        }
        """.utf8)
        var pluginRegistry = USDPluginRegistry()

        let plugins = try pluginRegistry.registerPlugInfo(from: plugInfo)
        let schemaRegistry = try USDSchemaRegistry(plugins: pluginRegistry.plugins)

        #expect(plugins.count == 1)
        #expect(pluginRegistry.plugin(named: "ExampleSchemas")?.type == .resource)
        #expect(pluginRegistry.declaredTypeNames == ["Hair", "PhysicsAPI"])
        #expect(pluginRegistry.pluginsDeclaring(typeName: "Hair").map(\.name) == ["ExampleSchemas"])
        #expect(schemaRegistry.isConcrete("Hair"))
        #expect(schemaRegistry.isA("Hair", "Xform"))
        #expect(schemaRegistry.isA("Hair", "Scope"))
        #expect(schemaRegistry.isAppliedAPISchema("PhysicsAPI"))
        #expect(schemaRegistry.definition(for: "Hair")?.propertyNames == ["points", "widths"])
        #expect(schemaRegistry.definition(for: "Hair")?.fallbackFields["purpose"] == .string("render"))

        let composed = try schemaRegistry.composedDefinition(primType: "Hair", appliedAPISchemas: ["PhysicsAPI"])
        #expect(composed.typeName == "Hair")
        #expect(composed.appliedAPISchemas == ["PhysicsAPI"])
        #expect(composed.propertyNames.contains("points"))
        #expect(composed.propertyNames.contains("physics:mass"))
        #expect(composed.fallbackFields["physics:mass"] == .double(1))

        var stage = USDStage.createInMemory()
        let prim = try stage.definePrim(at: SdfPath("/Groom"), typeName: "Hair")
        #expect(prim.isA("Xform", registry: schemaRegistry))
        #expect(!prim.isA("PhysicsAPI", registry: schemaRegistry))
        #expect(throws: USDError.self) {
            _ = try schemaRegistry.composedDefinition(primType: "Hair", appliedAPISchemas: ["Hair"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdPluginRegistryResolvesIncludesAndGeneratedSchemaDefinitions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-openusd-plugin-\(UUID().uuidString)")
        let schemaDirectory = directory.appendingPathComponent("schemas")
        try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
            }
        }

        let rootPlugInfoURL = directory.appendingPathComponent("plugInfo.json")
        let schemaPlugInfoURL = schemaDirectory.appendingPathComponent("plugInfo.json")
        let generatedSchemaURL = schemaDirectory.appendingPathComponent("generatedSchema.usda")
        try Data("""
        {
            "Includes": [
                "schemas/"
            ]
        }
        """.utf8).write(to: rootPlugInfoURL)
        try Data("""
        {
            "Plugins": [
                {
                    "Type": "resource",
                    "Name": "GeneratedSchemas",
                    "Root": ".",
                    "ResourcePath": ".",
                    "Info": {
                        "Types": {
                            "UsdGeomImageable": {
                                "autoGenerated": true,
                                "bases": ["UsdTyped"],
                                "schemaIdentifier": "Imageable",
                                "schemaKind": "abstractTyped"
                            },
                            "UsdGeomXform": {
                                "autoGenerated": true,
                                "bases": ["UsdGeomImageable"],
                                "schemaIdentifier": "Xform",
                                "schemaKind": "concreteTyped"
                            },
                            "UsdGeomMesh": {
                                "autoGenerated": true,
                                "bases": ["UsdGeomXform"],
                                "schemaIdentifier": "Mesh",
                                "schemaKind": "concreteTyped"
                            },
                            "UsdGeomVisibilityAPI": {
                                "autoGenerated": true,
                                "bases": ["UsdAPISchemaBase"],
                                "schemaIdentifier": "VisibilityAPI",
                                "schemaKind": "singleApplyAPI"
                            },
                            "UsdCollectionAPI": {
                                "apiSchemaPropertyNamespacePrefix": "collection",
                                "autoGenerated": true,
                                "bases": ["UsdAPISchemaBase"],
                                "schemaIdentifier": "CollectionAPI",
                                "schemaKind": "multipleApplyAPI"
                            }
                        }
                    }
                }
            ]
        }
        """.utf8).write(to: schemaPlugInfoURL)
        try Data("""
        #usda 1.0

        class "Imageable"
        {
            token visibility = "inherited"
        }

        class Xform "Xform"
        {
            uniform token[] xformOpOrder
        }

        class Mesh "Mesh"
        {
            point3f[] points
            uniform token subdivisionScheme = "catmullClark"
        }

        class "VisibilityAPI"
        {
            token visibility = "inherited"
        }

        class "CollectionAPI"
        {
            bool includeRoot = false
            rel includes
        }
        """.utf8).write(to: generatedSchemaURL)
        var pluginRegistry = USDPluginRegistry()

        let plugins = try pluginRegistry.registerPlugInfo(at: rootPlugInfoURL)
        let schemaRegistry = try USDSchemaRegistry(plugins: plugins, includeBuiltInDefinitions: false)
        let mesh = try #require(schemaRegistry.definition(for: "Mesh"))
        let composed = try schemaRegistry.composedDefinition(
            primType: "Mesh",
            appliedAPISchemas: ["VisibilityAPI", "CollectionAPI:hero"]
        )

        #expect(plugins.map(\.name) == ["GeneratedSchemas"])
        #expect(pluginRegistry.declaredTypeNames.contains("UsdGeomMesh"))
        #expect(schemaRegistry.definition(for: "UsdGeomMesh") == nil)
        #expect(schemaRegistry.isA("Mesh", "Xform"))
        #expect(schemaRegistry.isA("Mesh", "Imageable"))
        #expect(mesh.schemaKind == .concreteTyped)
        #expect(mesh.fallbackPrimTypes == ["Xform"])
        #expect(mesh.propertyNames.contains("points"))
        #expect(mesh.fallbackFields["subdivisionScheme"] == .token("catmullClark"))
        #expect(schemaRegistry.isAppliedAPISchema("CollectionAPI:hero"))
        #expect(composed.propertyNames.contains("visibility"))
        #expect(composed.propertyNames.contains("collection:hero:includeRoot"))
        #expect(composed.fallbackFields["collection:hero:includeRoot"] == .bool(false))
        #expect(throws: USDError.self) {
            _ = try schemaRegistry.composedDefinition(primType: "Mesh", appliedAPISchemas: ["CollectionAPI"])
        }
        #expect(throws: USDError.self) {
            _ = try schemaRegistry.composedDefinition(primType: "Mesh", appliedAPISchemas: ["VisibilityAPI:hero"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdPluginRegistryRejectsInvalidPlugInfoContracts() throws {
        var registry = USDPluginRegistry()

        #expect(throws: USDError.self) {
            _ = try registry.registerPlugInfo(from: Data("""
            {
                "Plugins": [
                    {
                        "Type": "library",
                        "Name": "MissingLibraryPath",
                        "Info": {}
                    }
                ]
            }
            """.utf8))
        }
        #expect(throws: USDError.self) {
            _ = try registry.registerPlugInfo(from: Data("""
            {
                "Type": "resource",
                "Name": "MissingInfo"
            }
            """.utf8))
        }
        #expect(throws: USDError.self) {
            _ = try registry.registerPlugInfo(from: Data("""
            {
                "Includes": ["child/plugInfo.json"]
            }
            """.utf8))
        }
        #expect(throws: USDError.self) {
            _ = try registry.registerPlugInfo(from: Data("""
            {
                "Plugins": {
                    "Type": "resource"
                }
            }
            """.utf8))
        }
        let malformedTypesPlugin = USDPlugin(
            type: .resource,
            name: "MalformedTypes",
            info: [
                "Types": .array([]),
            ]
        )
        #expect(throws: USDError.self) {
            _ = try USDSchemaRegistry(plugins: [malformedTypesPlugin], includeBuiltInDefinitions: false)
        }
        let missingSchemaKindPlugin = USDPlugin(
            type: .resource,
            name: "MissingSchemaKind",
            info: [
                "Types": .dictionary([
                    "UsdGeomMesh": .dictionary([
                        "schemaIdentifier": .string("Mesh"),
                    ]),
                ]),
            ]
        )
        #expect(throws: USDError.self) {
            _ = try USDSchemaRegistry(plugins: [missingSchemaKindPlugin], includeBuiltInDefinitions: false)
        }
        let badStringArrayPlugin = USDPlugin(
            type: .resource,
            name: "BadStringArray",
            info: [
                "Types": .dictionary([
                    "Hair": .dictionary([
                        "schemaKind": .string("concreteTyped"),
                        "propertyNames": .array([.string("points"), .number(1)]),
                    ]),
                ]),
            ]
        )
        #expect(throws: USDError.self) {
            _ = try USDSchemaRegistry(plugins: [badStringArrayPlugin], includeBuiltInDefinitions: false)
        }
        let generatedWithoutSchemaFilePlugin = USDPlugin(
            type: .resource,
            name: "GeneratedWithoutSchemaFile",
            info: [
                "Types": .dictionary([
                    "UsdGeomMesh": .dictionary([
                        "autoGenerated": .bool(true),
                        "schemaIdentifier": .string("Mesh"),
                        "schemaKind": .string("concreteTyped"),
                    ]),
                ]),
            ]
        )
        #expect(throws: USDError.self) {
            _ = try USDSchemaRegistry(plugins: [generatedWithoutSchemaFilePlugin], includeBuiltInDefinitions: false)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfSpecAndLayerValidateAuthoringInvariants() throws {
        #expect(throws: USDError.self) {
            try SdfSpec(path: "/Root", specType: .attribute).validate()
        }
        #expect(throws: USDError.self) {
            try SdfSpec(path: "/Root.value", specType: .prim).validate()
        }
        #expect(throws: USDError.self) {
            try SdfSpec(path: "/Root.target", specType: .relationshipTarget).validate()
        }
        #expect(throws: USDError.self) {
            try SdfSpec(
                path: "/Root",
                specType: .prim,
                fieldNames: ["displayName", "displayName"],
                fields: ["displayName": .authored("\"Root\"")]
            ).validate()
        }

        let duplicateLayer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(path: "/Root", specType: .prim, specifier: .def),
            SdfSpec(path: "/Root", specType: .prim, specifier: .over),
        ])
        let orphanPropertyLayer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: "/Missing.value",
                specType: .attribute,
                typeName: "double",
                fields: ["default": .authored("1")]
            ),
        ])

        #expect(throws: USDError.self) {
            try duplicateLayer.validate()
        }
        #expect(throws: USDError.self) {
            try orphanPropertyLayer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerRejectsUnmaterializedFieldsOnUSDAExport() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(path: "/Root", specType: .prim, specifier: .def),
            SdfSpec(
                path: "/Root.unsupported",
                specType: .attribute,
                typeName: "matrix2d",
                fieldNames: ["default"],
                fields: ["default": .unmaterializedValue]
            ),
        ])

        #expect(throws: USDError.self) {
            _ = try layer.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerImportsEditsAndExportsUSDAWithoutLosingFields() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 0.01
            upAxis = "Z"
        )

        def Xform "Root" (
            displayName = "Hero Root"
        )
        {
            custom uniform double width (
                displayName = "Width"
            ) = 2.5

            add rel look:binding = [</Looks/Mat>]

            variantSet "modelingVariant" = {
                "high" {
                    def Scope "HighGeom"
                    {
                    }
                }
            }
        }
        """.utf8)
        var layer = try SdfLayer.importUSDA(from: data, identifier: "anon:test")
        let rootPath = try SdfPath("/Root")
        let widthPath = try SdfPath("/Root.width")
        let relationshipPath = try SdfPath("/Root.look:binding")
        let materialPath = try SdfPath("/Looks/Mat")
        let variantSetPath = try SdfPath("/Root{modelingVariant}")
        let variantPath = try SdfPath("/Root{modelingVariant=high}")

        #expect(layer.identifier == "anon:test")
        #expect(layer.defaultPrim == "Root")
        #expect(layer.metersPerUnit == 0.01)
        #expect(layer.upAxis == .z)
        #expect(layer.listFields(at: rootPath).contains("specifier"))
        #expect(layer.field(named: "displayName", at: rootPath)?.authoredText == "\"Hero Root\"")
        #expect(layer.field(named: "displayName", at: widthPath)?.authoredText == "\"Width\"")
        #expect(layer.field(named: "targetPaths", at: relationshipPath)?.pathListOperation?.addedItems == [materialPath])
        #expect(layer.spec(at: variantSetPath)?.specType == .variantSet)
        #expect(layer.spec(at: variantPath)?.specType == .variant)

        try layer.setField(.authored("\"tool-authored\""), for: "documentation", at: rootPath)
        try layer.clearField(named: "displayName", at: rootPath)
        try layer.setField(
            .pathListOperation(SdfListOperation(isExplicit: true, explicitItems: [materialPath])),
            for: "targetPaths",
            at: relationshipPath
        )

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written, identifier: "anon:roundtrip")

        #expect(written.contains("documentation = \"tool-authored\""))
        #expect(!written.contains("displayName = \"Hero Root\""))
        #expect(written.contains("rel look:binding = </Looks/Mat>"))
        #expect(roundTripped.field(named: "documentation", at: rootPath)?.authoredText == "\"tool-authored\"")
        #expect(roundTripped.field(named: "displayName", at: rootPath) == nil)
        #expect(roundTripped.field(named: "targetPaths", at: relationshipPath)?.pathListOperation?.explicitItems == [materialPath])
        #expect(roundTripped.spec(at: variantPath)?.specType == .variant)
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerImportsRelationshipTargetsWithRelativePaths() throws {
        let layer = try SdfLayer.importUSDA(
            from: openUSDFixture("testSdfParsing.testenv/32_relationship_syntax.usda")
        )
        let relationshipPath = try SdfPath("/foo/Scope.rel_relative_path")
        let targetPath = try SdfPath("/foo/Scope.rel_relative_path[..]")
        let relativeTarget = try SdfPath("..")
        let relationship = try #require(layer.spec(at: relationshipPath))

        #expect(relationship.specType == .relationship)
        #expect(layer.spec(at: targetPath)?.specType == .relationshipTarget)
        #expect(relationship.field(named: "targetPaths")?.pathListOperation == SdfListOperation(
            isExplicit: true,
            explicitItems: [relativeTarget]
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerPreservesTypedUSDCFieldValues() throws {
        let metadataLayer = try SdfLayer(
            usdcLayer: try USDCReader().readLayer(from: makeUSDCLayerMetadataFieldFixture())
        )
        let rootPath = SdfPath.absoluteRoot
        let scopePath = try SdfPath("/Scope")
        let scopeTargetPath = try SdfPath("/Scope.target")
        let payloadTargetPath = try SdfPath("/PayloadTarget")

        #expect(metadataLayer.field(named: "subLayers", at: rootPath) == .stringVector([
            "layers/base.usda",
            "layers/anim.usdc",
        ]))
        #expect(metadataLayer.field(named: "subLayerOffsets", at: rootPath) == .layerOffsetVector([
            SdfLayerOffset(offset: 10, scale: 0.5),
            .identity,
        ]))
        #expect(metadataLayer.field(named: "variantSelections", at: scopePath) == .variantSelectionMap([
            "lod": "render",
            "modelingVariant": "high",
        ]))

        let listLayer = try SdfLayer(
            usdcLayer: try USDCReader().readLayer(from: makeUSDCLayerListOperationFixture())
        )
        #expect(listLayer.field(named: "tokenListOperation", at: scopePath) == .tokenListOperation(SdfListOperation(
            isExplicit: true,
            explicitItems: ["tokenExplicit"],
            addedItems: ["tokenAdded"],
            prependedItems: ["tokenPrepended"],
            appendedItems: ["tokenAppended"],
            deletedItems: ["tokenDeleted"],
            orderedItems: ["tokenOrdered"]
        )))
        #expect(listLayer.field(named: "pathListOperation", at: scopePath) == .pathListOperation(SdfListOperation(
            prependedItems: [rootPath],
            appendedItems: [scopeTargetPath],
            deletedItems: [scopePath],
            orderedItems: [scopeTargetPath]
        )))

        let compositionLayer = try SdfLayer(
            usdcLayer: try USDCReader().readLayer(from: makeUSDCLayerCompositionArcFixture())
        )
        let reference = SdfReference(
            assetPath: "assets/ref.usda",
            primPath: scopeTargetPath,
            layerOffset: SdfLayerOffset(offset: 1.5, scale: 2),
            customData: [
                "displayName": .string("friendlyRef"),
                "referencePurpose": .string("render"),
            ]
        )
        let secondReference = SdfReference(assetPath: "assets/second.usda", primPath: scopeTargetPath)
        #expect(compositionLayer.field(named: "references", at: scopePath) == .referenceListOperation(SdfListOperation(
            addedItems: [reference, secondReference],
            deletedItems: [secondReference],
            orderedItems: [reference]
        )))
        #expect(compositionLayer.field(named: "payload", at: scopePath) == .payloadListOperation(SdfListOperation(
            prependedItems: [
                SdfPayload(
                    assetPath: "assets/payload.usdc",
                    primPath: payloadTargetPath,
                    layerOffset: SdfLayerOffset(offset: -2, scale: 0.5)
                ),
            ]
        )))
        #expect(compositionLayer.field(named: "singlePayload", at: scopePath) == .payload(SdfPayload(
            assetPath: "assets/single.usda",
            primPath: scopePath
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportsTypedCompositionListOperationsWithoutLoss() throws {
        let scopePath = try SdfPath("/Scope")
        let modelPath = try SdfPath("/Model")
        let payloadTargetPath = try SdfPath("/PayloadTarget")
        let primaryReference = SdfReference(
            assetPath: "assets/ref.usda",
            primPath: modelPath,
            layerOffset: SdfLayerOffset(offset: 1.5, scale: 2),
            customData: [
                "displayName": .string("friendlyRef"),
                "samples": .doubleArray([1.25, 2]),
                "visible": .bool(true),
            ]
        )
        let deleteReference = SdfReference(assetPath: "assets/delete.usda")
        let appendReference = SdfReference(assetPath: "assets/append.usda", primPath: modelPath)
        let payload = SdfPayload(
            assetPath: "assets/payload.usdc",
            primPath: payloadTargetPath,
            layerOffset: SdfLayerOffset(offset: -2, scale: 0.5)
        )
        let appendedPayload = SdfPayload(assetPath: "assets/appendedPayload.usda")
        let referenceOperation = SdfListOperation(
            isExplicit: true,
            explicitItems: [primaryReference],
            appendedItems: [appendReference],
            deletedItems: [deleteReference],
            orderedItems: [primaryReference]
        )
        let payloadOperation = SdfListOperation(
            prependedItems: [payload],
            appendedItems: [appendedPayload],
            deletedItems: [SdfPayload(assetPath: "assets/oldPayload.usda")]
        )
        let layer = SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(
                path: scopePath,
                specType: .prim,
                specifier: .def,
                typeName: "Scope",
                fieldNames: ["references", "payload"],
                fields: [
                    "references": .referenceListOperation(referenceOperation),
                    "payload": .payloadListOperation(payloadOperation),
                ]
            ),
            SdfSpec(path: modelPath, specType: .prim, specifier: .def),
            SdfSpec(path: payloadTargetPath, specType: .prim, specifier: .def),
        ])

        let written = try layer.exportUSDA()
        let roundTripped = try SdfLayer.importUSDA(from: written)

        #expect(written.contains("references = @assets/ref.usda@</Model>"))
        #expect(written.contains("customData = { string displayName = \"friendlyRef\"; double[] samples = [1.25, 2.0]; bool visible = true }"))
        #expect(written.contains("delete references = @assets/delete.usda@"))
        #expect(written.contains("append references = @assets/append.usda@</Model>"))
        #expect(written.contains("prepend payload = @assets/payload.usdc@</PayloadTarget> (offset = -2.0; scale = 0.5)"))
        #expect(roundTripped.field(named: "references", at: scopePath) == .referenceListOperation(referenceOperation))
        #expect(roundTripped.field(named: "payload", at: scopePath) == .payloadListOperation(payloadOperation))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageFromSdfLayerRejectsUnsupportedSdfFieldsOnExport() throws {
        let layer = try SdfLayer(specs: [
            SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
            SdfSpec(path: "/Root", specType: .prim, specifier: .def),
            SdfSpec(
                path: "/Root.unsupported",
                specType: .attribute,
                typeName: "matrix2d",
                fieldNames: ["default"],
                fields: ["default": .unmaterializedValue]
            ),
        ])
        let stage = USDStage(rootLayer: layer)

        #expect(throws: USDError.self) {
            _ = try layer.exportUSDA()
        }
        #expect(throws: USDError.self) {
            _ = try stage.exportUSDA()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerExportPreservesStructuredCompositionArcs() throws {
        var layer = try SdfLayer(
            defaultPrim: "Scene",
            metersPerUnit: 1,
            upAxis: .z,
            specs: [
                SdfSpec(path: .absoluteRoot, specType: .pseudoRoot),
                SdfSpec(path: "/Scene", specType: .prim, specifier: .def),
            ]
        )
        let scenePath = try SdfPath("/Scene")
        try layer.setSublayers([
            USDSublayer(
                assetPath: "./layers/base.usda",
                layerOffset: SdfLayerOffset(offset: 10, scale: 0.5)
            ),
        ])
        try layer.setField(
            .referenceListOperation(SdfListOperation(isExplicit: true, explicitItems: [
                SdfReference(
                    assetPath: "./refs/model.usda",
                    primPath: try SdfPath("/Model"),
                    layerOffset: SdfLayerOffset(offset: 24, scale: 2)
                ),
            ])),
            for: "references",
            at: scenePath
        )
        try layer.setField(
            .payloadListOperation(SdfListOperation(isExplicit: true, explicitItems: [
                SdfPayload(
                    assetPath: "./payloads/heavy.usdc",
                    primPath: try SdfPath("/Payload"),
                    layerOffset: SdfLayerOffset(offset: -3, scale: 0.25)
                ),
            ])),
            for: "payload",
            at: scenePath
        )

        let written = try layer.exportUSDA()
        let roundTripped = try USDAReader().readLayer(from: written)

        #expect(written.contains("subLayers = [@./layers/base.usda@ (offset = 10.0; scale = 0.5)]"))
        #expect(written.contains("references = @./refs/model.usda@</Model> (offset = 24.0; scale = 2.0)"))
        #expect(written.contains("payload = @./payloads/heavy.usdc@</Payload> (offset = -3.0; scale = 0.25)"))
        #expect(roundTripped.composition.sublayers == layer.composition.sublayers)
        #expect(roundTripped.composition.references == layer.composition.references)
        #expect(roundTripped.composition.payloads == layer.composition.payloads)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageDefinesUsdGeomMeshAndExportsUSDA() throws {
        var stage = USDStage.createInMemory(metersPerUnit: 0.01, upAxis: .z)
        let world = try USDGeomXform.define(in: &stage, at: SdfPath("/World"))
        try world.setTranslate(USDTransformVector3D(x: 10, y: 0, z: 0), in: &stage)
        let mesh = try USDGeomMesh.define(in: &stage, at: SdfPath("/World/Geom/Triangle"))
        try mesh.setTopology(
            points: [
                USDPoint3D(x: 0, y: 0, z: 0),
                USDPoint3D(x: 1, y: 0, z: 0),
                USDPoint3D(x: 0, y: 1, z: 0),
            ],
            faceVertexCounts: [3],
            faceVertexIndices: [0, 1, 2],
            in: &stage
        )
        try mesh.setSubdivisionScheme("none", in: &stage)
        let worldPath = try SdfPath("/World")
        try stage.setDefaultPrim(try #require(stage.prim(at: worldPath)))

        let written = try stage.exportUSDA()
        let sdfLayer = try stage.exportSdfLayer()
        let stageFromSdf = USDStage(rootLayer: sdfLayer)
        let geomPath = try SdfPath("/World/Geom")
        let trianglePath = try SdfPath("/World/Geom/Triangle")
        let layer = try USDAReader().readLayer(from: written)
        let scene = try USDAReader().read(from: written)

        #expect(written.contains("defaultPrim = \"World\""))
        #expect(written.contains("def Xform \"World\""))
        #expect(written.contains("def \"Geom\""))
        #expect(written.contains("def Mesh \"Triangle\""))
        #expect(written.contains("double3 xformOp:translate = (10.0, 0.0, 0.0)"))
        #expect(written.contains("uniform token[] xformOpOrder = [\"xformOp:translate\"]"))
        #expect(written.contains("point3f[] points = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]"))
        #expect(written.contains("int[] faceVertexCounts = [3]"))
        #expect(written.contains("int[] faceVertexIndices = [0, 1, 2]"))
        #expect(written.contains("uniform token subdivisionScheme = \"none\""))
        #expect(stage.prim(at: geomPath)?.isDefined == true)
        #expect(layer.defaultPrim == "World")
        #expect(layer.spec(at: "/World")?.typeName == "Xform")
        #expect(layer.spec(at: "/World/Geom")?.specifier == .def)
        #expect(layer.spec(at: "/World/Geom")?.typeName == nil)
        #expect(layer.spec(at: "/World/Geom/Triangle")?.typeName == "Mesh")
        #expect(layer.spec(at: "/World/Geom/Triangle.points")?.fields["default"] != nil)
        #expect(sdfLayer.defaultPrim == "World")
        #expect(sdfLayer.spec(at: trianglePath)?.typeName == "Mesh")
        #expect(try stageFromSdf.exportUSDA() == written)
        #expect(scene.meshes.count == 1)
        #expect(scene.meshes.first?.primPath == "/World/Geom/Triangle")
        #expect(scene.meshes.first?.points == [
            USDPoint3D(x: 10, y: 0, z: 0),
            USDPoint3D(x: 11, y: 0, z: 0),
            USDPoint3D(x: 10, y: 1, z: 0),
        ])
        #expect(scene.meshes.first?.faceVertexCounts == [3])
        #expect(scene.meshes.first?.faceVertexIndices == [0, 1, 2])
        #expect(scene.meshes.first?.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageResolvesSublayersReferencesAndPayloadsWithLayerProvider() throws {
        let modelPath = try SdfPath("/Model")
        let payloadRootPath = try SdfPath("/PayloadRoot")
        let baseLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/World", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(
                path: "/World/Base",
                specType: .prim,
                specifier: .def,
                typeName: "Scope",
                fields: ["displayName": .authored("\"base\"")]
            ),
        ])
        let referenceLayer = USDALayer(defaultPrim: "Model", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(path: "/Model/Geom", specType: .prim, specifier: .def, typeName: "Mesh"),
        ])
        let payloadLayer = USDALayer(defaultPrim: "PayloadRoot", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/PayloadRoot", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(path: "/PayloadRoot/Heavy", specType: .prim, specifier: .def, typeName: "Mesh"),
        ])
        let rootLayer = USDALayer(
            defaultPrim: "World",
            composition: USDLayerComposition(sublayers: [USDSublayer(assetPath: "base.usda")]),
            specs: [
                USDLayerSpec(path: "/", specType: .pseudoRoot),
                USDLayerSpec(path: "/World", specType: .prim, specifier: .def, typeName: "Xform"),
                USDLayerSpec(
                    path: "/World/Base",
                    specType: .prim,
                    specifier: .over,
                    fields: ["displayName": .authored("\"root\"")]
                ),
                USDLayerSpec(
                    path: "/World/Referenced",
                    specType: .prim,
                    specifier: .over,
                    fieldNames: ["references"],
                    fields: [
                        "references": .referenceListOperation(SdfListOperation(
                            prependedItems: [SdfReference(assetPath: "refs/model.usda", primPath: modelPath)]
                        )),
                    ]
                ),
                USDLayerSpec(
                    path: "/World/Payloaded",
                    specType: .prim,
                    specifier: .over,
                    fieldNames: ["payload"],
                    fields: [
                        "payload": .payloadListOperation(SdfListOperation(
                            prependedItems: [SdfPayload(assetPath: "payloads/heavy.usda", primPath: payloadRootPath)]
                        )),
                    ]
                ),
            ]
        )
        let provider = try makeInMemoryProvider([
            "base.usda": baseLayer,
            "refs/model.usda": referenceLayer,
            "payloads/heavy.usda": payloadLayer,
        ])
        let stage = USDStage(rootLayer: rootLayer)
        let referencedGeomPath = try SdfPath("/World/Referenced/Geom")
        let payloadedHeavyPath = try SdfPath("/World/Payloaded/Heavy")

        #expect(stage.prim(at: referencedGeomPath) == nil)

        let flattened = try stage.flattenedLayer(resolvingWith: provider, rootIdentifier: "root.usda")
        let resolvedStage = try stage.resolved(resolvingWith: provider, rootIdentifier: "root.usda")

        #expect(try stage.prim(at: referencedGeomPath, resolvingWith: provider, rootIdentifier: "root.usda") == USDPrim(
            path: referencedGeomPath,
            specifier: .def,
            typeName: "Mesh"
        ))
        #expect(resolvedStage.prim(at: payloadedHeavyPath) == USDPrim(
            path: payloadedHeavyPath,
            specifier: .def,
            typeName: "Mesh"
        ))
        #expect(flattened.spec(at: "/World/Base")?.specifier == .def)
        #expect(flattened.spec(at: "/World/Base")?.fields["displayName"] == .authored("\"root\""))
        #expect(flattened.spec(at: "/World/Referenced")?.typeName == "Xform")
        #expect(flattened.spec(at: "/World/Referenced")?.fields["references"] == nil)
        #expect(flattened.spec(at: "/World/Payloaded")?.fields["payload"] == nil)
        #expect(flattened.composition.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageComposesCrossLayerReferenceAndPayloadListOperations() throws {
        let modelPath = try SdfPath("/Model")
        let payloadPath = try SdfPath("/Payload")
        let referenceA = SdfReference(assetPath: "../assets/referenceA.usda", primPath: modelPath)
        let referenceB = SdfReference(assetPath: "../assets/referenceB.usda", primPath: modelPath)
        let payloadA = SdfPayload(assetPath: "../assets/payloadA.usda", primPath: payloadPath)
        let payloadB = SdfPayload(assetPath: "../assets/payloadB.usda", primPath: payloadPath)
        let weakLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/World/SublayerOnly",
                specType: .prim,
                specifier: .def,
                fields: ["displayName": .authored("\"weak\"")]
            ),
            USDLayerSpec(
                path: "/World/RootOpinion",
                specType: .prim,
                specifier: .def,
                fields: ["displayName": .authored("\"weak\"")]
            ),
            USDLayerSpec(
                path: "/World/DeleteReference",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(isExplicit: true, explicitItems: [referenceA, referenceB])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ReorderReference",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(isExplicit: true, explicitItems: [referenceA, referenceB])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ExplicitReference",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(isExplicit: true, explicitItems: [referenceA])),
                ]
            ),
            USDLayerSpec(
                path: "/World/DeletePayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "payload": .payloadListOperation(SdfListOperation(isExplicit: true, explicitItems: [payloadA, payloadB])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ReorderPayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "payload": .payloadListOperation(SdfListOperation(isExplicit: true, explicitItems: [payloadA, payloadB])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ExplicitPayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "payload": .payloadListOperation(SdfListOperation(isExplicit: true, explicitItems: [payloadA])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ReferenceBeatsPayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [referenceB])),
                    "payload": .payloadListOperation(SdfListOperation(prependedItems: [payloadA])),
                ]
            ),
        ])
        let strongLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/World/SublayerOnly",
                specType: .prim,
                specifier: .over,
                fields: ["displayName": .authored("\"strong\"")]
            ),
            USDLayerSpec(
                path: "/World/RootOpinion",
                specType: .prim,
                specifier: .over,
                fields: ["displayName": .authored("\"strong\"")]
            ),
            USDLayerSpec(
                path: "/World/DeleteReference",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(deletedItems: [referenceA])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ReorderReference",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(orderedItems: [referenceB, referenceA])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ExplicitReference",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(isExplicit: true, explicitItems: [referenceB])),
                ]
            ),
            USDLayerSpec(
                path: "/World/DeletePayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "payload": .payloadListOperation(SdfListOperation(deletedItems: [payloadA])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ReorderPayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "payload": .payloadListOperation(SdfListOperation(orderedItems: [payloadB, payloadA])),
                ]
            ),
            USDLayerSpec(
                path: "/World/ExplicitPayload",
                specType: .prim,
                specifier: .over,
                fields: [
                    "payload": .payloadListOperation(SdfListOperation(isExplicit: true, explicitItems: [payloadB])),
                ]
            ),
        ])
        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [
                USDSublayer(assetPath: "./layers/strong.usda"),
                USDSublayer(assetPath: "./layers/weak.usda"),
            ]),
            specs: [
                USDLayerSpec(path: "/", specType: .pseudoRoot),
                USDLayerSpec(path: "/World", specType: .prim, specifier: .def, typeName: "Xform"),
                USDLayerSpec(
                    path: "/World/RootOpinion",
                    specType: .prim,
                    specifier: .over,
                    fields: ["displayName": .authored("\"root\"")]
                ),
            ]
        )
        let provider = try makeInMemoryProvider([
            "scene/layers/weak.usda": weakLayer,
            "scene/layers/strong.usda": strongLayer,
            "scene/assets/referenceA.usda": referenceLayer(name: "referenceA", rootPath: "/Model", uniqueChildName: "OnlyA"),
            "scene/assets/referenceB.usda": referenceLayer(name: "referenceB", rootPath: "/Model", uniqueChildName: "OnlyB"),
            "scene/assets/payloadA.usda": referenceLayer(name: "payloadA", rootPath: "/Payload", uniqueChildName: "OnlyA"),
            "scene/assets/payloadB.usda": referenceLayer(name: "payloadB", rootPath: "/Payload", uniqueChildName: "OnlyB"),
        ])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "scene/root.usda"
        )

        #expect(flattened.spec(at: "/World/SublayerOnly")?.fields["displayName"] == .authored("\"strong\""))
        #expect(flattened.spec(at: "/World/RootOpinion")?.fields["displayName"] == .authored("\"root\""))
        #expect(flattened.spec(at: "/World/DeleteReference/OnlyA") == nil)
        #expect(flattened.spec(at: "/World/DeleteReference/OnlyB")?.typeName == "Mesh")
        #expect(flattened.spec(at: "/World/ReorderReference/Shared")?.fields["displayName"] == .authored("\"referenceB\""))
        #expect(flattened.spec(at: "/World/ExplicitReference/OnlyA") == nil)
        #expect(flattened.spec(at: "/World/ExplicitReference/OnlyB")?.typeName == "Mesh")
        #expect(flattened.spec(at: "/World/DeletePayload/OnlyA") == nil)
        #expect(flattened.spec(at: "/World/DeletePayload/OnlyB")?.typeName == "Mesh")
        #expect(flattened.spec(at: "/World/ReorderPayload/Shared")?.fields["displayName"] == .authored("\"payloadB\""))
        #expect(flattened.spec(at: "/World/ExplicitPayload/OnlyA") == nil)
        #expect(flattened.spec(at: "/World/ExplicitPayload/OnlyB")?.typeName == "Mesh")
        #expect(flattened.spec(at: "/World/ReferenceBeatsPayload/Shared")?.fields["displayName"] == .authored("\"referenceB\""))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageResolvesInternalReferencesAndDefaultPrimFromTargetLayerStacks() throws {
        let prototypePath = try SdfPath("/Prototype")
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: "/Prototype", specType: .prim, specifier: .def, typeName: "Xform"),
            USDLayerSpec(path: "/Prototype/Geom", specType: .prim, specifier: .def, typeName: "Mesh"),
            USDLayerSpec(path: "/Outside", specType: .prim, specifier: .def, typeName: "Mesh"),
            USDLayerSpec(
                path: "/Instance",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "", primPath: prototypePath),
                    ])),
                ]
            ),
            USDLayerSpec(
                path: "/DefaultFromRoot",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "targets/defaultFromRoot.usda"),
                    ])),
                ]
            ),
        ])
        let provider = try makeInMemoryProvider([
            "targets/base.usda": USDALayer(defaultPrim: "Model", specs: [
                USDLayerSpec(path: "/", specType: .pseudoRoot),
                USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
                USDLayerSpec(path: "/Model/Geom", specType: .prim, specifier: .def, typeName: "Mesh"),
            ]),
            "targets/defaultFromRoot.usda": USDALayer(
                defaultPrim: "RootModel",
                composition: USDLayerComposition(sublayers: [USDSublayer(assetPath: "base.usda")]),
                specs: [
                    USDLayerSpec(path: "/", specType: .pseudoRoot),
                    USDLayerSpec(path: "/RootModel", specType: .prim, specifier: .def, typeName: "Xform"),
                    USDLayerSpec(path: "/RootModel/RootGeom", specType: .prim, specifier: .def, typeName: "Mesh"),
                ]
            ),
        ])

        let flattened = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: "root.usda"
        )

        #expect(flattened.spec(at: "/Instance/Geom")?.typeName == "Mesh")
        #expect(flattened.spec(at: "/Instance/Outside") == nil)
        #expect(flattened.spec(at: "/DefaultFromRoot/RootGeom")?.typeName == "Mesh")
        #expect(flattened.spec(at: "/DefaultFromRoot/Geom") == nil)

        let missingDefaultPrimLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Broken",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(prependedItems: [
                        SdfReference(assetPath: "targets/noDefault.usda"),
                    ])),
                ]
            ),
        ])
        let missingDefaultPrimProvider = try makeInMemoryProvider([
            "targets/noDefault.usda": USDALayer(specs: [
                USDLayerSpec(path: "/", specType: .pseudoRoot),
                USDLayerSpec(path: "/Model", specType: .prim, specifier: .def, typeName: "Xform"),
            ]),
        ])
        #expect(throws: USDError.self) {
            _ = try USDStage(rootLayer: missingDefaultPrimLayer).flattenedLayer(
                resolvingWith: missingDefaultPrimProvider,
                rootIdentifier: "root.usda"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageCompositionReportsMissingAssetsAndCycles() throws {
        let missingLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .over,
                fields: [
                    "references": .referenceListOperation(SdfListOperation(
                        prependedItems: [SdfReference(assetPath: "missing.usda", primPath: try SdfPath("/Missing"))]
                    )),
                ]
            ),
        ])
        let missingStage = USDStage(rootLayer: missingLayer)

        #expect(throws: USDError.self) {
            _ = try missingStage.flattenedLayer(resolvingWith: USDInMemoryLayerProvider(), rootIdentifier: "root.usda")
        }

        let rootLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [USDSublayer(assetPath: "loop.usda")]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let loopLayer = USDALayer(
            composition: USDLayerComposition(sublayers: [USDSublayer(assetPath: "root.usda")]),
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        )
        let cycleStage = USDStage(rootLayer: rootLayer)
        let provider = try makeInMemoryProvider([
            "root.usda": rootLayer,
            "loop.usda": loopLayer,
        ])

        #expect(throws: USDError.self) {
            _ = try cycleStage.flattenedLayer(resolvingWith: provider, rootIdentifier: "root.usda")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageAuthorsOverridesClassesAndRelationships() throws {
        var stage = USDStage.createInMemory()
        _ = try stage.createClassPrim(at: SdfPath("/_ModelBase"))
        _ = try stage.overridePrim(at: SdfPath("/World/Looks"))
        _ = try stage.createRelationship(
            at: SdfPath("/World"),
            name: "look:binding",
            targetPaths: SdfListOperation(addedItems: [SdfPath("/World/Looks")])
        )

        let written = try stage.exportUSDA()
        let layer = try USDAReader().readLayer(from: written)

        #expect(written.contains("class \"_ModelBase\""))
        #expect(written.contains("over \"Looks\""))
        #expect(written.contains("add rel look:binding = [</World/Looks>]"))
        #expect(layer.spec(at: "/_ModelBase")?.specifier == .class)
        #expect(layer.spec(at: "/World")?.specifier == .def)
        #expect(layer.spec(at: "/World/Looks")?.specifier == .over)
        #expect(layer.spec(at: "/World.look:binding")?.fields["targetPaths"] == .pathListOperation(SdfListOperation(
            addedItems: ["/World/Looks"]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageAuthoringRejectsInvalidSpecs() throws {
        var stage = USDStage.createInMemory()

        #expect(throws: USDError.self) {
            _ = try stage.definePrim(at: SdfPath("Relative"), typeName: "Xform")
        }
        #expect(throws: USDError.self) {
            _ = try stage.createClassPrim(at: SdfPath("/World/Class"))
        }
        #expect(throws: USDError.self) {
            _ = try stage.createAttribute(at: SdfPath("/Missing"), name: "value", typeName: "double", defaultValue: "1")
        }

        let mesh = try USDGeomMesh.define(in: &stage, at: SdfPath("/World/Triangle"))
        #expect(throws: USDError.self) {
            try mesh.setTopology(
                points: [USDPoint3D(x: 0, y: 0, z: 0)],
                faceVertexCounts: [3],
                faceVertexIndices: [0, 1, 2],
                in: &stage
            )
        }
        #expect(throws: USDError.self) {
            try mesh.setPoints([USDPoint3D(x: .nan, y: 0, z: 0)], in: &stage)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageDefinePrimPreservesExistingFields() throws {
        var stage = USDStage.createInMemory()
        _ = try stage.definePrim(at: SdfPath("/World"), typeName: "Xform")
        _ = try stage.createAttribute(at: SdfPath("/World"), name: "width", typeName: "double", defaultValue: "2")
        _ = try stage.createRelationship(
            at: SdfPath("/World"),
            name: "look:binding",
            targetPaths: SdfListOperation(addedItems: [SdfPath("/Looks/Mat")])
        )

        _ = try stage.definePrim(at: SdfPath("/World"), typeName: "Xform")
        let layer = try stage.exportSdfLayer()
        let worldPath = try SdfPath("/World")
        let widthPath = try SdfPath("/World.width")
        let relationshipPath = try SdfPath("/World.look:binding")
        let materialPath = try SdfPath("/Looks/Mat")
        let world = try #require(layer.spec(at: worldPath))

        #expect(world.field(named: "properties")?.authoredText == "/World.width, /World.look:binding")
        #expect(layer.spec(at: widthPath)?.field(named: "default") == .authored("2"))
        #expect(layer.spec(at: relationshipPath)?.field(named: "targetPaths") == .pathListOperation(SdfListOperation(
            addedItems: [materialPath]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageRelationshipRejectsInvalidTargets() throws {
        var stage = USDStage.createInMemory()
        _ = try stage.definePrim(at: SdfPath("/World"))

        for invalidTarget in ["", "bad target", "/World.rel[/Nested]"] {
            #expect(throws: USDError.self) {
                _ = try stage.createRelationship(
                    at: SdfPath("/World"),
                    name: "target",
                    targetPaths: SdfListOperation(addedItems: [SdfPath(invalidTarget)])
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdGeomXformPreservesExistingXformOpOrder() throws {
        var stage = USDStage.createInMemory()
        let xform = try USDGeomXform.define(in: &stage, at: SdfPath("/World"))
        _ = try stage.createAttribute(
            at: SdfPath("/World"),
            name: "xformOpOrder",
            typeName: "token[]",
            defaultValue: "[\"!resetXformStack!\", \"xformOp:rotateXYZ\"]",
            variability: .uniform
        )

        try xform.setTranslate(USDTransformVector3D(x: 1, y: 2, z: 3), in: &stage)
        try xform.setTranslate(USDTransformVector3D(x: 4, y: 5, z: 6), in: &stage)

        let orderSpec = try #require(stage.rootLayer.spec(at: "/World.xformOpOrder"))
        let translateSpec = try #require(stage.rootLayer.spec(at: "/World.xformOp:translate"))

        #expect(orderSpec.fields["default"] == .authored("[\"!resetXformStack!\", \"xformOp:rotateXYZ\", \"xformOp:translate\"]"))
        #expect(translateSpec.fields["default"] == .authored("(4.0, 5.0, 6.0)"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdGeomMeshIndividualSettersValidateAuthoredTopology() throws {
        var stage = USDStage.createInMemory()
        let mesh = try USDGeomMesh.define(in: &stage, at: SdfPath("/World/Triangle"))

        try mesh.setPoints([USDPoint3D(x: 0, y: 0, z: 0)], in: &stage)
        try mesh.setFaceVertexCounts([3], in: &stage)
        #expect(throws: USDError.self) {
            try mesh.setFaceVertexIndices([0, 1, 2], in: &stage)
        }
        #expect(stage.rootLayer.spec(at: "/World/Triangle.faceVertexIndices") == nil)

        try mesh.setPoints([
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ], in: &stage)
        try mesh.setFaceVertexIndices([0, 1, 2], in: &stage)

        #expect(stage.rootLayer.spec(at: "/World/Triangle.faceVertexIndices")?.fields["default"] == .authored("[0, 1, 2]"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaWriterRoundTripsSceneMesh() throws {
        let scene = USDScene(
            defaultPrim: "Triangle",
            metersPerUnit: 0.01,
            upAxis: .z,
            meshes: [
                USDMesh(
                    name: "Triangle",
                    points: [
                        USDPoint3D(x: 0, y: 0, z: 0),
                        USDPoint3D(x: 1, y: 0, z: 0),
                        USDPoint3D(x: 0, y: 1, z: 0),
                    ],
                    faceVertexCounts: [3],
                    faceVertexIndices: [0, 1, 2],
                    orientation: .rightHanded,
                    subdivisionScheme: "none"
                )
            ]
        )

        let written = try USDAWriter().string(for: scene)
        let roundTripped = try USDAReader().read(from: written)

        #expect(written.contains("def Mesh \"Triangle\""))
        #expect(roundTripped.defaultPrim == "Triangle")
        #expect(roundTripped.metersPerUnit == 0.01)
        #expect(roundTripped.upAxis == .z)
        #expect(roundTripped.meshes.first?.points == scene.meshes.first?.points)
        #expect(roundTripped.meshes.first?.faceVertexCounts == [3])
        #expect(roundTripped.meshes.first?.faceVertexIndices == [0, 1, 2])
        #expect(roundTripped.meshes.first?.orientation == .rightHanded)
        #expect(roundTripped.meshes.first?.subdivisionScheme == "none")
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingMetadataSyntaxFixturesReadLayers() throws {
        let testCases: [(fixturePath: String, primPaths: [String])] = [
            ("testSdfParsing.testenv/104_uniformAttributes.usda", ["/bool_tests"]),
            ("testSdfParsing.testenv/113_displayName_metadata.usda", ["/Rig", "/Rig/Leg", "/RightLeg"]),
            ("testSdfParsing.testenv/115_symmetricPeer_metadata.usda", ["/test"]),
            ("testSdfParsing.testenv/127_varyingRelationship.usda", ["/Sphere"]),
            ("testSdfParsing.testenv/187_displayName_metadata.usda", ["/Rig", "/Rig/Leg"]),
        ]

        for testCase in testCases {
            let layer = try USDAReader().readLayer(from: openUSDFixture(testCase.fixturePath))

            #expect(layer.prims.map(\.path).sorted() == testCase.primPaths.sorted())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingStringSubstitutionMetadataFixturePreservesMaps() throws {
        let layer = try SdfLayer.importUSDA(from: openUSDFixture("testSdfParsing.testenv/113_displayName_metadata.usda"))
        let primPath = try SdfPath("/RightLeg")

        #expect(layer.field(named: "prefixSubstitutions", at: primPath) == .dictionary([
            "$Left": .string("Right"),
            "Left": .string("Right"),
        ]))
        #expect(layer.field(named: "suffixSubstitutions", at: primPath) == .dictionary([
            "$NUM": .string("1"),
        ]))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadTypeNameSyntaxFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/53_bad_typeName.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("unterminated"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadHiddenMetadataFixturesThrowTypedErrors() throws {
        for fixturePath in [
            "testSdfParsing.testenv/80_bad_hidden.usda",
            "testSdfParsing.testenv/94_bad_hiddenAttr.usda",
            "testSdfParsing.testenv/95_bad_hiddenRel.usda",
        ] {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains("hidden metadata"))
            #expect(message.contains("bad"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadBoolPrimMetadataFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/64_bad_boolPrimInstantiate.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("hidden metadata"))
        #expect(message.contains("bad"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadAccessMetadataFixturesThrowTypedErrors() throws {
        for fixturePath in [
            "testSdfParsing.testenv/17_bad_attributeaccess.usda",
            "testSdfParsing.testenv/18_bad_primaccess.usda",
            "testSdfParsing.testenv/19_bad_relationshipaccess.usda",
        ] {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains("access metadata"))
            #expect(message.contains("foo"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingRelationshipNoLoadHintFixtureReadsLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/154_relationship_noLoadHint.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path) == ["/Root"])
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadRelationshipNoLoadHintFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/155_bad_relationship_noLoadHint.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("noLoadHint metadata"))
        #expect(message.contains("hoovooloo"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingPermissionMetadataFixtureReadsLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/116_permission_metadata.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path).sorted() == [
            "/TestPrim",
            "/TestPrim/PrivateChild",
            "/TestPrim/PublicChild",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadPermissionMetadataFixturesThrowTypedErrors() throws {
        for fixturePath in [
            "testSdfParsing.testenv/117_bad_permission_metadata.usda",
            "testSdfParsing.testenv/118_bad_permission_metadata_2.usda",
            "testSdfParsing.testenv/119_bad_permission_metadata_3.usda",
        ] {
            let data = try openUSDFixture(fixturePath)

            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: data)
            }

            #expect(message.contains("permission metadata"))
            #expect(message.contains("bogus"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingKindMetadataFixtureReadsLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/149_kind_metadata.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path) == ["/TestPrim"])
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingRelocatesMetadataFixturesReadLayers() throws {
        for fixturePath in [
            "testSdfParsing.testenv/139_relocates_metadata.usda",
            "testSdfParsing.testenv/148_relocates_empty_map.usda",
        ] {
            let layer = try USDAReader().readLayer(from: openUSDFixture(fixturePath))

            #expect(layer.prims.map(\.path) == ["/TestPrim"])
            #expect(layer.composition.isEmpty)
            let testPrim = try #require(layer.spec(at: "/TestPrim"))
            #expect(testPrim.specifier == .def)
            #expect(testPrim.typeName == "MfScope")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadRelocatesMetadataFixturesThrowTypedErrors() throws {
        let cases = [
            ("testSdfParsing.testenv/140_bad_relocates_paths_1.usda", "relocates source path", "pseudo-root"),
            ("testSdfParsing.testenv/141_bad_relocates_paths_2.usda", "relocates target path", "invalid path characters"),
            ("testSdfParsing.testenv/142_bad_relocates_paths_3.usda", "relocates source path", "empty"),
            ("testSdfParsing.testenv/143_bad_relocates_formatting_1.usda", "relocates metadata", "map"),
            ("testSdfParsing.testenv/144_bad_relocates_formatting_2.usda", "relocates source path", "angle brackets"),
            ("testSdfParsing.testenv/145_bad_relocates_formatting_3.usda", "relocates metadata entries", "commas"),
            ("testSdfParsing.testenv/146_bad_relocates_formatting_4.usda", "source and target", "':'"),
            ("testSdfParsing.testenv/147_bad_relocates_formatting_5.usda", "relocates metadata entries", "commas"),
            ("testSdfParsing.testenv/216_bad_variant_in_relocates_path.usda", "relocates metadata", "map"),
        ]

        for (fixturePath, expectedSubject, expectedDetail) in cases {
            let message = try usdImportFailureMessage {
                _ = try USDAReader().readLayer(from: openUSDFixture(fixturePath))
            }

            #expect(message.contains(expectedSubject))
            #expect(message.contains(expectedDetail))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadKindMetadataFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/150_bad_kind_metadata_1.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("kind metadata"))
        #expect(message.contains("model"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingReferencesFixtureReadsSupportedExternalArcs() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/132_references.usda")

        let layer = try USDAReader().readLayer(from: data)
        let references = layer.composition.references

        #expect(references.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestPrim1",
            targetPrimPath: "/Prim"
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "///test/layer2.usda",
            sitePrimPath: "/TestPrim2",
            targetPrimPath: "/Prim2"
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestPrim3",
            targetPrimPath: "/Prim",
            layerOffset: SdfLayerOffset(offset: 11, scale: 22)
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestFile1",
            targetPrimPath: nil
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestFile5",
            targetPrimPath: nil,
            layerOffset: SdfLayerOffset(offset: 11, scale: 22)
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "/test/layer3.usda",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: "/Prim"
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "/test/layer4.usda",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: nil
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "/test/layer3.usda",
            sitePrimPath: "/TestMixed3",
            targetPrimPath: "/Prim"
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "/test/layer4.usda",
            sitePrimPath: "/TestMixed3",
            targetPrimPath: nil
        )))
        let additionalReferences = [
            USDCompositionArc(
                assetPath: "///test/layer.usda",
                sitePrimPath: "/TestFile2",
                targetPrimPath: nil
            ),
            USDCompositionArc(
                assetPath: "///test/layer2.usda",
                sitePrimPath: "/TestFile2",
                targetPrimPath: nil
            ),
            USDCompositionArc(
                assetPath: "///test1/layer1.usda",
                sitePrimPath: "/TestFile3",
                targetPrimPath: nil,
                layerOffset: SdfLayerOffset(offset: 0.1, scale: 0.2)
            ),
            USDCompositionArc(
                assetPath: "///test/layer.usda",
                sitePrimPath: "/TestSubrootPrim1",
                targetPrimPath: "/Prim/Child"
            ),
            USDCompositionArc(
                assetPath: "///test/layer2.usda",
                sitePrimPath: "/TestSubrootPrim2",
                targetPrimPath: "/Prim2/Child"
            ),
            USDCompositionArc(
                assetPath: "///test/layer.usda",
                sitePrimPath: "/TestSubrootPrim3",
                targetPrimPath: "/Prim/Child",
                layerOffset: SdfLayerOffset(offset: 11, scale: 22)
            ),
            USDCompositionArc(
                assetPath: "///test1/layer1.usda",
                sitePrimPath: "/TestSubrootPrim3",
                targetPrimPath: "/Prim2/Child",
                layerOffset: SdfLayerOffset(offset: 0.1, scale: 0.2)
            ),
        ]
        for expected in additionalReferences {
            #expect(references.contains(expected))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadReferenceFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/133_bad_reference.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("asset path"))
        #expect(message.contains("empty"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderAppliesCompositionArcListEdits() throws {
        let data = Data("""
        #usda 1.0

        def "Scope" (
            references = [
                @./a.usda@</A>,
                @./b.usda@</B>
            ]
            delete references = @./a.usda@</A>
            prepend references = [
                @./c.usda@</C>
            ]
            append references = [
                @./b.usda@</B>,
                @./d.usda@</D>
            ]
            reorder references = [
                @./d.usda@</D>,
                @./c.usda@</C>
            ]
            payload = [
                @./p1.usda@</P1>,
                @./p2.usda@</P2>
            ]
            delete payload = @./p2.usda@</P2>
            append payload = [
                @./p3.usda@</P3>
            ]
        )
        {
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.composition.references == [
            USDCompositionArc(assetPath: "./d.usda", sitePrimPath: "/Scope", targetPrimPath: "/D"),
            USDCompositionArc(assetPath: "./c.usda", sitePrimPath: "/Scope", targetPrimPath: "/C"),
            USDCompositionArc(assetPath: "./b.usda", sitePrimPath: "/Scope", targetPrimPath: "/B"),
        ])
        #expect(layer.composition.payloads == [
            USDCompositionArc(assetPath: "./p1.usda", sitePrimPath: "/Scope", targetPrimPath: "/P1"),
            USDCompositionArc(assetPath: "./p3.usda", sitePrimPath: "/Scope", targetPrimPath: "/P3"),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderIgnoresCompositionReferencesInsideCommentsAndStrings() throws {
        let data = Data("""
        #usda 1.0

        def "Scope" (
            references = [
                @./real.usda@</Real>, # @./comment.usda@</Comment>
            ]
            customData = {
                string note = "@./string.usda@</String>"
            }
        )
        {
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.composition.references == [
            USDCompositionArc(assetPath: "./real.usda", sitePrimPath: "/Scope", targetPrimPath: "/Real"),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderRejectsUnexpectedCompositionReferenceContent() throws {
        let data = Data("""
        #usda 1.0

        def "Scope" (
            references = [
                @./real.usda@</Real>,
                garbage
            ]
        )
        {
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("composition arc list"))
        #expect(message.contains("unexpected content"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderReadsSemicolonTerminatedCompositionReference() throws {
        let data = Data("""
        #usda 1.0

        def "Scope" (
            references = @./real.usda@</Real>;
        )
        {
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.composition.references == [
            USDCompositionArc(assetPath: "./real.usda", sitePrimPath: "/Scope", targetPrimPath: "/Real"),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderRejectsInvalidCompositionTargetPrimPath() throws {
        let data = Data("""
        #usda 1.0

        def "Scope" (
            references = @./real.usda@<bad path>
        )
        {
        }
        """.utf8)

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("composition arc prim path"))
        #expect(message.contains("invalid path characters"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderTreatsAssetLiteralsAsOpaqueDuringValidation() throws {
        let data = Data("""
        #usda 1.0

        def "Scope"
        {
            asset source = @hidden = maybe@
            asset[] files = [
                @foo[bar]@,
                @def Mesh "NotADeclaration" {}@
            ]
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.spec(at: "/Scope") != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderTreatsEndTokenInsideAssetLiteralAsOpaque() throws {
        let data = Data("""
        #usda 1.0

        def "Scope"
        {
            asset source = @/__END__.usd@
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.spec(at: "/Scope") != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderKeepsChildPrimAfterAssetLiteralContainingBrace() throws {
        let data = Data("""
        #usda 1.0

        def Xform "Root"
        {
            asset source = @weird{path.usda@

            def Scope "Child"
            {
            }
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.spec(at: "/Root.source") != nil)
        #expect(layer.spec(at: "/Root/Child") != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderTreatsPrimKeywordInsideDepthZeroAssetLiteralAsOpaque() throws {
        let data = Data("""
        #usda 1.0

        def Xform "Root"
        {
            asset source = @my def model.usda@

            def Scope "Child"
            {
            }
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.spec(at: "/Root.source") != nil)
        #expect(layer.spec(at: "/Root/Child") != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaLayerReaderIgnoresCompositionListEditsInsideNestedMetadata() throws {
        let data = Data("""
        #usda 1.0

        def "Scope" (
            customData = {
                asset marker = @add references = ./ignored.usda@
                string text = "reorder payload = @./ignored.usda@"
            }
            references = @./real.usda@</Real>
        )
        {
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.composition.references == [
            USDCompositionArc(assetPath: "./real.usda", sitePrimPath: "/Scope", targetPrimPath: "/Real"),
        ])
        #expect(layer.composition.payloads.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingPayloadsFixtureReadsSupportedExternalArcs() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/152_payloads.usda")

        let layer = try USDAReader().readLayer(from: data)
        let payloads = layer.composition.payloads

        #expect(payloads.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestPrim1",
            targetPrimPath: "/Prim"
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "///test/layer2.usda",
            sitePrimPath: "/TestPrim2",
            targetPrimPath: "/Prim2"
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestPrim3",
            targetPrimPath: "/Prim",
            layerOffset: SdfLayerOffset(offset: 11, scale: 22)
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestFile1",
            targetPrimPath: nil
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "///test/layer.usda",
            sitePrimPath: "/TestFile5",
            targetPrimPath: nil,
            layerOffset: SdfLayerOffset(offset: 11, scale: 22)
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "/test/layer3.usda",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: "/Prim"
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "/test/layer4.usda",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: nil
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "/test/layer3.usda",
            sitePrimPath: "/TestMixed3",
            targetPrimPath: "/Prim"
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "/test/layer4.usda",
            sitePrimPath: "/TestMixed3",
            targetPrimPath: nil
        )))
        let additionalPayloads = [
            USDCompositionArc(
                assetPath: "///test/layer.usda",
                sitePrimPath: "/TestFile2",
                targetPrimPath: nil
            ),
            USDCompositionArc(
                assetPath: "///test/layer2.usda",
                sitePrimPath: "/TestFile2",
                targetPrimPath: nil
            ),
            USDCompositionArc(
                assetPath: "///test1/layer1.usda",
                sitePrimPath: "/TestFile3",
                targetPrimPath: nil,
                layerOffset: SdfLayerOffset(offset: 0.1, scale: 0.2)
            ),
            USDCompositionArc(
                assetPath: "///test/layer.usda",
                sitePrimPath: "/TestSubrootPrim1",
                targetPrimPath: "/Prim/Child"
            ),
            USDCompositionArc(
                assetPath: "///test/layer2.usda",
                sitePrimPath: "/TestSubrootPrim2",
                targetPrimPath: "/Prim2/Child"
            ),
            USDCompositionArc(
                assetPath: "///test/layer.usda",
                sitePrimPath: "/TestSubrootPrim3",
                targetPrimPath: "/Prim/Child",
                layerOffset: SdfLayerOffset(offset: 11, scale: 22)
            ),
            USDCompositionArc(
                assetPath: "///test1/layer1.usda",
                sitePrimPath: "/TestSubrootPrim3",
                targetPrimPath: "/Prim2/Child",
                layerOffset: SdfLayerOffset(offset: 0.1, scale: 0.2)
            ),
        ]
        for expected in additionalPayloads {
            #expect(payloads.contains(expected))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFParsingBadPayloadsFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/153_bad_payloads.usda")

        let message = try usdImportFailureMessage {
            _ = try USDAReader().readLayer(from: data)
        }

        #expect(message.contains("payload"))
        #expect(message.contains("list-edit"))
        #expect(message.contains("bracketed list"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDReadOutOfBoundsFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testUsdReadOutOfBounds/corrupt.usd")

        let message = try usdImportFailureMessage {
            _ = try USDCReader().readLayer(from: data)
        }

        #expect(message.contains("outside") || message.contains("truncated") || message.contains("overlap"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDCSecurityFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testUsdUsdcBugGHSA02.testenv/root.usdc")

        let message = try usdImportFailureMessage {
            _ = try USDCReader().readLayer(from: data)
        }

        #expect(
            message.contains("decompress")
            || message.contains("repeated")
            || message.contains("outside")
            || message.contains("PATHS")
            || message.contains("invalid")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDZSecurityFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testUsdUsdzBugGHSA01.testenv/root.usdz")

        let message = try usdImportFailureMessage {
            _ = try USDZReader().readLayerGraph(from: data)
        }

        #expect(message.contains("spec type") || message.contains("CRC") || message.contains("outside"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFUSDCInvalidPrimChildrenFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfUsdcInvalidPrimChildren.testenv/root.usdc")

        let layerMessage = try usdImportFailureMessage {
            _ = try USDCReader().readLayer(from: data)
        }
        let sceneMessage = try usdImportFailureMessage {
            _ = try USDCReader().read(from: data)
        }

        #expect(layerMessage.contains("primChildren"))
        #expect(layerMessage.contains("invalid"))
        #expect(sceneMessage.contains("primChildren"))
        #expect(sceneMessage.contains("invalid"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSDFUSDCDuplicatePrimChildrenFixtureThrowsTypedError() throws {
        let data = try openUSDFixture("testSdfUsdcInvalidPrimChildren.testenv/duplicate_prim_children.usdc")

        let layerMessage = try usdImportFailureMessage {
            _ = try USDCReader().readLayer(from: data)
        }
        let sceneMessage = try usdImportFailureMessage {
            _ = try USDCReader().read(from: data)
        }

        #expect(layerMessage.contains("primChildren"))
        #expect(layerMessage.contains("duplicate child Child1"))
        #expect(sceneMessage.contains("primChildren"))
        #expect(sceneMessage.contains("duplicate child Child1"))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesTokenVectorFieldValues() throws {
        let fixture = makeUSDCLayerTokenVectorFixture()

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.specifier == .def)
        #expect(scope.typeName == "Scope")
        #expect(scope.fieldNames == ["properties", "specifier", "typeName"])
        #expect(scope.fields["specifier"] == .specifier(.def))
        #expect(scope.fields["typeName"] == .token("Scope"))
        #expect(scope.fields["properties"] == .tokenVector(["firstProperty", "secondProperty"]))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesAssetPathAndPathVectorFieldValues() throws {
        let fixture = makeUSDCLayerAssetPathAndPathVectorFixture()

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.fields["assetPath"] == .assetPath("assets/model.usda"))
        #expect(scope.fields["pathVector"] == .pathVector(["/", "/Scope"]))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesMetadataFieldValues() throws {
        let fixture = makeUSDCLayerMetadataFieldFixture()

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let root = try #require(layer.spec(at: "/"))
        #expect(root.fields["subLayers"] == .stringVector(["layers/base.usda", "layers/anim.usdc"]))
        #expect(root.fields["subLayerOffsets"] == .layerOffsetVector([
            SdfLayerOffset(offset: 10, scale: 0.5),
            .identity,
        ]))
        #expect(layer.composition.sublayers == [
            USDSublayer(assetPath: "layers/base.usda", layerOffset: SdfLayerOffset(offset: 10, scale: 0.5)),
            USDSublayer(assetPath: "layers/anim.usdc"),
        ])

        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.fields["variantSelections"] == .variantSelectionMap([
            "lod": "render",
            "modelingVariant": "high",
        ]))
        #expect(scope.fields["permission"] == .permission(.privateAccess))
        #expect(scope.fields["variability"] == .variability(.uniform))
        #expect(scope.fields["timeCodeValue"] == .timeCode(24))
        #expect(scope.fields["timeCodeArray"] == .timeCodeArray([1, 2.5]))
        #expect(scope.fields["stringVector"] == .stringVector(["alpha", "beta"]))
        #expect(scope.fields["doubleVector"] == .doubleVector([1.25, 2.5]))
        #expect(scope.fields["dictionaryValue"] == .dictionary([:]))
        #expect(scope.fields["unsupportedMatrix2d"] == .unmaterializedValue(USDCUnmaterializedValue(
            typeName: "matrix2d",
            rawType: USDCCrateValueType.matrix2d.rawValue,
            payload: 123,
            isArray: false,
            isInlined: true,
            isCompressed: false,
            isArrayEdit: false
        )))
        #expect(scope.fields["unknownRawValue"] == .unmaterializedValue(USDCUnmaterializedValue(
            typeName: "unknown(250)",
            rawType: 250,
            payload: 456,
            isArray: true,
            isInlined: true,
            isCompressed: true,
            isArrayEdit: true
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesNumericFieldValues() throws {
        let fixture = makeUSDCLayerNumericFieldFixture()

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.fields["intValue"] == .int(-42))
        #expect(scope.fields["boolValue"] == .bool(true))
        #expect(scope.fields["ucharValue"] == .int(255))
        #expect(scope.fields["uintValue"] == .int(42))
        #expect(scope.fields["int64Value"] == .int(-84))
        #expect(scope.fields["uint64Value"] == .int(84))
        #expect(scope.fields["vec2fValue"] == .point2(USDPoint2D(x: 1.5, y: -2.25)))
        #expect(scope.fields["vec2dValue"] == .point2(USDPoint2D(x: 3.25, y: 4.5)))
        #expect(scope.fields["doubleArray"] == .doubleArray([1.25, 2.5]))
        #expect(scope.fields["boolArray"] == .boolArray([true, false, true]))
        #expect(scope.fields["ucharArray"] == .intArray([1, 255]))
        #expect(scope.fields["uintArray"] == .intArray([42, 84]))
        #expect(scope.fields["int64Array"] == .intArray([-84, 168]))
        #expect(scope.fields["uint64Array"] == .intArray([84, 168]))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesCompressedNumericArrayFieldValues() throws {
        let fixture = makeUSDCLayerNumericFieldFixture(compressedArrays: true)

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.fields["doubleArray"] == .doubleArray([1.25, 2.5]))
        #expect(scope.fields["boolArray"] == .boolArray([true, false, true]))
        #expect(scope.fields["ucharArray"] == .intArray([1, 255]))
        #expect(scope.fields["uintArray"] == .intArray([42, 84]))
        #expect(scope.fields["int64Array"] == .intArray([-84, 168]))
        #expect(scope.fields["uint64Array"] == .intArray([84, 168]))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesListOperationFieldValues() throws {
        let fixture = makeUSDCLayerListOperationFixture()

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.fields["tokenListOperation"] == .tokenListOperation(USDCListOperation(
            isExplicit: true,
            explicitItems: ["tokenExplicit"],
            addedItems: ["tokenAdded"],
            prependedItems: ["tokenPrepended"],
            appendedItems: ["tokenAppended"],
            deletedItems: ["tokenDeleted"],
            orderedItems: ["tokenOrdered"]
        )))
        #expect(scope.fields["stringListOperation"] == .stringListOperation(USDCListOperation(
            isExplicit: true,
            addedItems: ["stringAdded"]
        )))
        #expect(scope.fields["pathListOperation"] == .pathListOperation(USDCListOperation(
            prependedItems: ["/"],
            appendedItems: ["/Scope.target"],
            deletedItems: ["/Scope"],
            orderedItems: ["/Scope.target"]
        )))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcLayerReaderPreservesCompositionArcFieldValues() throws {
        let fixture = makeUSDCLayerCompositionArcFixture()

        let layer = try USDCReader().readLayer(from: fixture)

        #expect(layer.specs.map(\.path) == ["/", "/Scope"])
        let scope = try #require(layer.spec(at: "/Scope"))
        #expect(scope.specType == .prim)
        #expect(scope.fields["references"] == .referenceListOperation(USDCListOperation(
            addedItems: [
                USDCReference(
                    assetPath: "assets/ref.usda",
                    primPath: "/Scope.target",
                    layerOffset: SdfLayerOffset(offset: 1.5, scale: 2),
                    customData: [
                        "displayName": .string("friendlyRef"),
                        "referencePurpose": .string("render"),
                    ]
                ),
                USDCReference(
                    assetPath: "assets/second.usda",
                    primPath: "/Scope.target"
                ),
            ],
            deletedItems: [
                USDCReference(
                    assetPath: "assets/second.usda",
                    primPath: "/Scope.target"
                ),
            ],
            orderedItems: [
                USDCReference(
                    assetPath: "assets/ref.usda",
                    primPath: "/Scope.target",
                    layerOffset: SdfLayerOffset(offset: 1.5, scale: 2),
                    customData: [
                        "displayName": .string("friendlyRef"),
                        "referencePurpose": .string("render"),
                    ]
                ),
            ]
        )))
        #expect(scope.fields["payload"] == .payloadListOperation(USDCListOperation(
            prependedItems: [
                USDCPayload(
                    assetPath: "assets/payload.usdc",
                    primPath: "/PayloadTarget",
                    layerOffset: SdfLayerOffset(offset: -2, scale: 0.5)
                ),
            ]
        )))
        #expect(scope.fields["singlePayload"] == .payload(USDCPayload(
            assetPath: "assets/single.usda",
            primPath: "/Scope"
        )))
        #expect(layer.composition.references == [
            USDCompositionArc(
                assetPath: "assets/ref.usda",
                sitePrimPath: "/Scope",
                targetPrimPath: "/Scope.target",
                layerOffset: SdfLayerOffset(offset: 1.5, scale: 2)
            ),
            USDCompositionArc(
                assetPath: "assets/second.usda",
                sitePrimPath: "/Scope",
                targetPrimPath: "/Scope.target"
            ),
        ])
        #expect(layer.composition.payloads == [
            USDCompositionArc(
                assetPath: "assets/payload.usdc",
                sitePrimPath: "/Scope",
                targetPrimPath: "/PayloadTarget",
                layerOffset: SdfLayerOffset(offset: -2, scale: 0.5)
            ),
            USDCompositionArc(
                assetPath: "assets/single.usda",
                sitePrimPath: "/Scope",
                targetPrimPath: "/Scope"
            ),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdLayerOffsetMapsBetweenLayerAndStageTime() throws {
        let offset = SdfLayerOffset(offset: 10, scale: 2)

        #expect(offset.stageTime(forLayerTime: 12) == 34)
        #expect(try offset.layerTime(forStageTime: 34) == 12)
        #expect(offset.concatenating(SdfLayerOffset(offset: 3, scale: 4)) == SdfLayerOffset(offset: 16, scale: 8))
    }

    @Test(.timeLimit(.minutes(1)))
    func usdaReaderPreservesLayerCompositionArcs() throws {
        let data = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
            subLayers = [
                @./layers/base.usda@ (offset = 10; scale = 0.5)
            ]
        )

        def "Scene" (
            references = [
                @./refs/model.usda@</Model> (offset = 24; scale = 2)
            ]
            payload = @./payloads/heavy.usdc@</Payload> (offset = -3; scale = 0.25)
        )
        {
        }
        """.utf8)

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.defaultPrim == "Scene")
        #expect(layer.metersPerUnit == 1)
        #expect(layer.upAxis == .z)
        #expect(layer.composition.sublayerAssetPaths == ["./layers/base.usda"])
        #expect(layer.composition.sublayers == [
            USDSublayer(
                assetPath: "./layers/base.usda",
                layerOffset: SdfLayerOffset(offset: 10, scale: 0.5)
            ),
        ])
        #expect(layer.composition.references == [
            USDCompositionArc(
                assetPath: "./refs/model.usda",
                sitePrimPath: "/Scene",
                targetPrimPath: "/Model",
                layerOffset: SdfLayerOffset(offset: 24, scale: 2)
            ),
        ])
        #expect(layer.composition.payloads == [
            USDCompositionArc(
                assetPath: "./payloads/heavy.usdc",
                sitePrimPath: "/Scene",
                targetPrimPath: "/Payload",
                layerOffset: SdfLayerOffset(offset: -3, scale: 0.25)
            ),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSingleUSDCFixtureReadsCompressedStructuralTables() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/single/test.usdc")

        let crate = try USDCReader().readCrate(from: data)

        #expect(crate.version == USDCCrateVersion(major: 0, minor: 7, patch: 0))
        try crate.requireStructuralSections()
        #expect(try crate.readTokens().contains("Root_USDC"))
        #expect(!((try crate.readFields()).isEmpty))
        #expect(!((try crate.readFieldSets()).isEmpty))
        #expect(try crate.readPaths() == ["/", "/Root_USDC"])
        let specs = try crate.readSpecs()
        #expect(specs == [
            USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
            USDCCrateSpec(pathIndex: 1, fieldSetIndex: 2, specType: .prim),
        ])
        let tokens = try crate.readTokens()
        let fields = try crate.readFields()
        let fieldSetIndexes = try crate.readFieldSetIndexes()
        #expect(fieldSetIndexes[2] == 1)
        #expect(tokens[Int(fields[1].tokenIndex)] == "specifier")
        #expect(fields[1].valueRep.type == .specifier)
        #expect(fields[1].valueRep.isInlined)
        #expect(fields[1].valueRep.payload == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDSingleUSDCFixtureReadsLayerSpecs() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/single/test.usdc")

        let layer = try USDCReader().readLayer(from: data)

        #expect(layer.defaultPrim == nil)
        #expect(layer.metersPerUnit == nil)
        #expect(layer.upAxis == nil)
        #expect(layer.specs.map(\.path) == ["/", "/Root_USDC"])
        #expect(layer.spec(at: "/")?.specType == .pseudoRoot)
        let root = try #require(layer.spec(at: "/Root_USDC"))
        #expect(root.specType == .prim)
        #expect(root.specifier == .def)
        #expect(root.typeName == nil)
        #expect(root.fieldNames.contains("specifier"))
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDZFixtureRejectsFirstFileThatIsNotUSDLayer() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/first_file_not_usd.usdz")

        #expect(throws: USDError.self) {
            _ = try USDZReader().read(from: data)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDZFixtureReadsUSDCArchiveDefaultLayer() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/single_usdc.usdz")
        let standaloneUSDC = try openUSDFixture("testUsdUsdzFileFormat/single/test.usdc")

        let archive = try USDZArchive(data: data)

        #expect(archive.centralDirectoryOffset == 627)
        #expect(archive.centralDirectorySize == 55)
        #expect(archive.endOfCentralDirectoryOffset == 682)
        #expect(archive.entries.count == 1)
        let defaultLayer = try #require(archive.defaultLayer)
        #expect(defaultLayer.path == "test.usdc")
        #expect(defaultLayer.fileExtension == "usdc")
        #expect(defaultLayer.isUSDLayer)
        #expect(defaultLayer.localHeaderOffset == 0)
        #expect(defaultLayer.localExtraFieldByteCount == 25)
        #expect(defaultLayer.dataOffset == 64)
        #expect(defaultLayer.isPayload64ByteAligned)
        #expect(defaultLayer.data.count == 563)
        #expect(defaultLayer.crc32 == 0x3157e80a)
        #expect(defaultLayer.data.starts(with: Data(USDCReader.fileSignature)))
        #expect(defaultLayer.data == standaloneUSDC)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDZFixtureReadsUSDCDefaultLayerSpecs() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/single_usdc.usdz")
        let archive = try USDZArchive(data: data)
        let defaultLayer = try #require(archive.defaultLayer)

        let layer = try USDCReader().readLayer(from: defaultLayer.data)

        #expect(layer.specs.map(\.path) == ["/", "/Root_USDC"])
        #expect(layer.spec(at: "/Root_USDC")?.specifier == .def)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDZFixturePreservesFirstFileAsDefaultLayer() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/first_file_not_usd.usdz")

        let archive = try USDZArchive(data: data)

        #expect(archive.centralDirectoryOffset == 7_386)
        #expect(archive.centralDirectorySize == 106)
        #expect(archive.endOfCentralDirectoryOffset == 7_492)
        #expect(archive.entries.map(\.path) == ["b.png", "test.usda"])
        let defaultEntry = try #require(archive.defaultLayer)
        #expect(defaultEntry.path == "b.png")
        #expect(defaultEntry.fileExtension == "png")
        #expect(!defaultEntry.isUSDLayer)
        #expect(defaultEntry.localHeaderOffset == 0)
        #expect(defaultEntry.localExtraFieldByteCount == 29)
        #expect(defaultEntry.dataOffset == 64)
        #expect(defaultEntry.isPayload64ByteAligned)
        #expect(defaultEntry.data.count == 7_228)
        #expect(defaultEntry.crc32 == 0x16ef5709)

        let usdaEntry = try #require(archive.entries.last)
        #expect(usdaEntry.path == "test.usda")
        #expect(usdaEntry.isUSDLayer)
        #expect(usdaEntry.localHeaderOffset == 7_292)
        #expect(usdaEntry.localExtraFieldByteCount == 29)
        #expect(usdaEntry.dataOffset == 7_360)
        #expect(usdaEntry.isPayload64ByteAligned)
        #expect(usdaEntry.data.count == 26)
        #expect(usdaEntry.crc32 == 0x31aafb7b)
    }

    @Test(.timeLimit(.minutes(1)))
    func openUSDUSDZFixtureWithUSDCDefaultLayerThrowsTypedUSDError() throws {
        let data = try openUSDFixture("testUsdUsdzFileFormat/single_usdc.usdz")

        #expect(throws: USDError.self) {
            _ = try USDZReader().read(from: data)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderRequiresStructuralSections() throws {
        let data = makeUSDCFixture(sections: [
            ("TOKENS", Data([0x01])),
        ])

        #expect(throws: USDError.self) {
            _ = try USDCReader().read(from: data)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsAlignedUSDADefaultLayer() throws {
        let usda = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("scene.usda", usda),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.defaultPrim == "Scene")
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.count == 1)
        #expect(scene.meshes.first?.points.count == 3)
        #expect(scene.meshes.first?.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderAppliesWeakerSublayerParentTransformToStrongerMesh() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "World"
            subLayers = [
                @base.usda@
            ]
        )

        over "World"
        {
            def Mesh "Geom"
            {
                double3 xformOp:translate = (0, 2, 0)
                uniform token[] xformOpOrder = ["xformOp:translate"]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
            }
        }
        """.utf8)
        let base = Data("""
        #usda 1.0

        def Xform "World"
        {
            double3 xformOp:translate = (10, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("base.usda", base),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        let mesh = try #require(scene.meshes.first)
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 10, y: 2, z: 0),
            USDPoint3D(x: 11, y: 2, z: 0),
            USDPoint3D(x: 10, y: 3, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderResolvesSameLayerPrimOnlyReferences() throws {
        let usda = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
        )

        def Xform "Scene"
        {
            def "Instance" (
                references = </Source>
            )
            {
            }
        }

        def Mesh "Source"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("scene.usda", usda),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.compactMap(\.primPath).sorted() == ["/Scene/Instance", "/Source"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsUSDAWhitespaceSeparatedMeshDeclaration() throws {
        let usda = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def    Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("scene.usda", usda),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.defaultPrim == "Scene")
        #expect(scene.meshes.map(\.name) == ["Triangle"])
        #expect(scene.meshes.first?.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderTraversesUSDASubLayers() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
            subLayers = [
                @./mesh.usda@
            ]
        )
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("mesh.usda", makeUSDAMeshLayer(name: "Triangle")),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.defaultPrim == "Scene")
        #expect(scene.upAxis == .z)
        #expect(scene.meshes.map(\.name) == ["Triangle"])
        #expect(scene.meshes.first?.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderComposesSubLayersInsteadOfDuplicatingMeshes() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "World"
            metersPerUnit = 1
            upAxis = "Z"
            subLayers = [
                @./strong.usda@,
                @./weak.usda@
            ]
        )
        """.utf8)
        let weak = Data("""
        #usda 1.0

        def Mesh "World"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "catmullClark"
        }
        """.utf8)
        let strong = Data("""
        #usda 1.0

        over "World"
        {
            point3f[] points = [(0, 0, 5), (1, 0, 5), (0, 1, 5)]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("weak.usda", weak),
            ("strong.usda", strong),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.count == 1)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.name == "World")
        #expect(mesh.primPath == "/World")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 5),
            USDPoint3D(x: 1, y: 0, z: 5),
            USDPoint3D(x: 0, y: 1, z: 5),
        ])
        #expect(mesh.subdivisionScheme == "none")
        #expect(mesh.faceVertexCounts == [3])
        #expect(mesh.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderTraversesUSDAReferences() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Scene" (
            references = @./refs/mesh.usda@</Triangle>
        )
        {
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/mesh.usda", makeUSDAMeshLayer(name: "Triangle")),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.defaultPrim == "Scene")
        #expect(scene.meshes.map(\.name) == ["Scene"])
        #expect(scene.meshes.map(\.primPath) == ["/Scene"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderFiltersReferenceTargetPrimPath() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Scene" (
            references = @./refs/meshes.usda@</Keep>
        )
        {
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Keep"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Keep"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }

        def Mesh "Drop"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/meshes.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.map(\.name) == ["Scene"])
        #expect(scene.meshes.map(\.primPath) == ["/Scene"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderAppliesReferenceSiteTransform() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/model.usda@</Model>
        )
        {
            double3 xformOp:translate = (10, 20, 30)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/model.usda", makeUSDAMeshLayer(name: "Model")),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 10, y: 20, z: 30),
            USDPoint3D(x: 11, y: 20, z: 30),
            USDPoint3D(x: 10, y: 21, z: 30),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderComposesSubrootTransformWithSameValuedReferenceSiteTransform() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/model.usda@</Model/Geom>
        )
        {
            double3 xformOp:translate = (0, 5, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Model"
        {
            def Mesh "Geom"
            {
                double3 xformOp:translate = (0, 5, 0)
                uniform token[] xformOpOrder = ["xformOp:translate"]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                uniform token subdivisionScheme = "none"
            }
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/model.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 0, y: 10, z: 0),
            USDPoint3D(x: 1, y: 10, z: 0),
            USDPoint3D(x: 0, y: 11, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderAppliesReferenceLayerOffsetToTimeSamples() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/animated.usda@</Triangle> (offset = 10; scale = 2)
        )
        {
        }
        """.utf8)
        let animatedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points.timeSamples = {
                1: [(0, 0, 0), (1, 0, 0), (0, 1, 0)],
                2: [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            }
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/animated.usda", animatedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package, options: USDReadingOptions(timeCode: 14))
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 1),
            USDPoint3D(x: 1, y: 0, z: 1),
            USDPoint3D(x: 0, y: 1, z: 1),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderTreatsExactBlockedPointTimeSampleAsMissingRequiredField() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(9, 9, 9), (10, 9, 9), (9, 10, 9)]
            point3f[] points.timeSamples = {
                1: None,
                2: [(0, 0, 2), (1, 0, 2), (0, 1, 2)]
            }
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [("root.usda", root)], alignPayloads: true)

        do {
            _ = try USDZReader().read(from: package, options: USDReadingOptions(timeCode: 1))
            Issue.record("Expected blocked points to be reported as a missing required field.")
        } catch USDError.missingRequiredField(let field) {
            #expect(field == "points")
        } catch {
            Issue.record("Expected missingRequiredField(\"points\"), got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderDoesNotFallBackToDefaultForBlockedOptionalPrimvar() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            color3f[] primvars:displayColor = [(1, 0, 0)]
            color3f[] primvars:displayColor.timeSamples = {
                1: None,
                2: [(0, 1, 0)]
            }
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [("root.usda", root)], alignPayloads: true)

        let scene = try USDZReader().read(from: package, options: USDReadingOptions(timeCode: 1))

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.displayColor == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderTreatsBlockedRequiredDefaultAsMissingRequiredField() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = None
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [("root.usda", root)], alignPayloads: true)

        do {
            _ = try USDZReader().read(from: package)
            Issue.record("Expected blocked default points to be reported as missing.")
        } catch USDError.missingRequiredField(let field) {
            #expect(field == "points")
        } catch {
            Issue.record("Expected missingRequiredField(\"points\"), got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderTreatsBlockedOptionalDefaultsAsNil() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            color3f[] primvars:displayColor = None
            uniform token orientation = None
            uniform token subdivisionScheme = None
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [("root.usda", root)], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        let mesh = try #require(scene.meshes.first)
        #expect(mesh.displayColor == nil)
        #expect(mesh.orientation == nil)
        #expect(mesh.subdivisionScheme == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderInterpolatesReferenceLayerOffsetTimeSamples() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/animated.usda@</Triangle> (offset = 10; scale = 2)
        )
        {
        }
        """.utf8)
        let animatedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points.timeSamples = {
                1: [(0, 0, 0), (1, 0, 0), (0, 1, 0)],
                2: [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            }
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/animated.usda", animatedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package, options: USDReadingOptions(timeCode: 13))
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0.5),
            USDPoint3D(x: 1, y: 0, z: 0.5),
            USDPoint3D(x: 0, y: 1, z: 0.5),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderPreservesHeldInterpolationThroughReferenceLayerOffset() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/animated.usda@</Triangle> (offset = 10; scale = 2)
        )
        {
        }
        """.utf8)
        let animatedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points.timeSamples = {
                1: [(0, 0, 0), (1, 0, 0), (0, 1, 0)],
                2: [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            }
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/animated.usda", animatedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(
            from: package,
            options: USDReadingOptions(timeCode: 13, timeSampleInterpolation: .held)
        )
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        #expect(mesh.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderDropsSourceAncestorTransformForSubrootReferences() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/model.usda@</Model/Geom>
        )
        {
            double3 xformOp:translate = (10, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Model"
        {
            double3 xformOp:translate = (100, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def Xform "Geom"
            {
                double3 xformOp:translate = (0, 5, 0)
                uniform token[] xformOpOrder = ["xformOp:translate"]

                def Mesh "Child"
                {
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                    uniform token subdivisionScheme = "none"
                }
            }
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/model.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Child")
        #expect(mesh.primPath == "/Scene/Child")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 10, y: 5, z: 0),
            USDPoint3D(x: 11, y: 5, z: 0),
            USDPoint3D(x: 10, y: 6, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderSubrootReferenceHonorsResetXformStackAtTarget() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/model.usda@</Model/Geom>
        )
        {
            double3 xformOp:translate = (10, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Model"
        {
            double3 xformOp:translate = (100, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]

            def Xform "Geom"
            {
                double3 xformOp:translate = (0, 5, 0)
                uniform token[] xformOpOrder = ["!resetXformStack!", "xformOp:translate"]

                def Mesh "Child"
                {
                    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                    int[] faceVertexCounts = [3]
                    int[] faceVertexIndices = [0, 1, 2]
                    uniform token subdivisionScheme = "none"
                }
            }
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/model.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Child")
        #expect(mesh.primPath == "/Scene/Child")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 10, y: 5, z: 0),
            USDPoint3D(x: 11, y: 5, z: 0),
            USDPoint3D(x: 10, y: 6, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderUSDCSubrootReferenceHonorsResetXformStackAtTarget() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            references = @./refs/model.usdc@</Model/Geom>
        )
        {
            double3 xformOp:translate = (10, 0, 0)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/model.usdc", makeUSDCResetSubrootMeshLayerFixture()),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 10, y: 5, z: 0),
            USDPoint3D(x: 11, y: 5, z: 0),
            USDPoint3D(x: 10, y: 6, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderIncludesReferenceTargetSubtreeMeshes() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Scene"
        {
            def "Instance" (
                references = @./refs/model.usda@</Model>
            )
            {
            }
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Model"
        {
            def Mesh "Child"
            {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                uniform token subdivisionScheme = "none"
            }
        }

        def Mesh "Outside"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/model.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.map(\.name) == ["Child"])
        #expect(scene.meshes.map(\.primPath) == ["/Scene/Instance/Child"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderIncludesPayloadTargetSubtreeMeshes() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Scene" (
            payload = @./payloads/model.usda@</Model>
        )
        {
        }
        """.utf8)
        let payloadLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Model"
        {
            def Mesh "PayloadChild"
            {
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                uniform token subdivisionScheme = "none"
            }
        }

        def Mesh "Outside"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("payloads/model.usda", payloadLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.map(\.name) == ["PayloadChild"])
        #expect(scene.meshes.map(\.primPath) == ["/Scene/PayloadChild"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderAppliesPayloadSiteTransform() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Xform "Scene" (
            payload = @./payloads/model.usda@</Model>
        )
        {
            double3 xformOp:translate = (10, 20, 30)
            uniform token[] xformOpOrder = ["xformOp:translate"]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("payloads/model.usda", makeUSDAMeshLayer(name: "Model")),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)
        let mesh = try #require(scene.meshes.first)

        #expect(mesh.name == "Scene")
        #expect(mesh.primPath == "/Scene")
        expectPointsApproximatelyEqual(mesh.points, [
            USDPoint3D(x: 10, y: 20, z: 30),
            USDPoint3D(x: 11, y: 20, z: 30),
            USDPoint3D(x: 10, y: 21, z: 30),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderUsesDefaultPrimForExplicitEmptyReferenceTarget() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Scene" (
            references = @./refs/meshes.usda@<>
        )
        {
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Keep"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Keep"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }

        def Mesh "Drop"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/meshes.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.map(\.name) == ["Scene"])
        #expect(scene.meshes.map(\.primPath) == ["/Scene"])
        #expect(scene.meshes.first?.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderDoesNotMaterializeReferenceWithoutDefaultPrimTarget() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Scene" (
            references = @./refs/meshes.usda@<>
        )
        {
            point3f[] points = [(10, 0, 0), (11, 0, 0), (10, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let referencedLayer = Data("""
        #usda 1.0
        (
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "LeakedA"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }

        def Mesh "LeakedB"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/meshes.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        guard scene.meshes.count == 1 else {
            Issue.record("Expected one local mesh, got \(scene.meshes.count).")
            return
        }
        guard let mesh = scene.meshes.first else {
            Issue.record("Expected a local mesh.")
            return
        }
        guard mesh.name == "Scene" else {
            Issue.record("Expected local mesh name Scene, got \(String(describing: mesh.name)).")
            return
        }
        guard mesh.primPath == "/Scene" else {
            Issue.record("Expected local mesh path /Scene, got \(String(describing: mesh.primPath)).")
            return
        }
        guard mesh.points == [
            USDPoint3D(x: 10, y: 0, z: 0),
            USDPoint3D(x: 11, y: 0, z: 0),
            USDPoint3D(x: 10, y: 1, z: 0),
        ] else {
            Issue.record("Unexpected local mesh points: \(mesh.points).")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderSkipsMissingDefaultPrimArcWithoutDroppingValidArcs() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Scene"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def "Scene"
        {
            def Mesh "Local"
            {
                point3f[] points = [(10, 0, 0), (11, 0, 0), (10, 1, 0)]
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                uniform token subdivisionScheme = "none"
            }

            def "Valid" (
                references = @./refs/valid.usda@</Triangle>
            )
            {
            }

            def "Invalid" (
                references = @./refs/missing-default.usda@<>
            )
            {
            }
        }
        """.utf8)
        let valid = Data("""
        #usda 1.0
        (
            defaultPrim = "Triangle"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let missingDefault = Data("""
        #usda 1.0

        def Mesh "Leaked"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
            ("refs/valid.usda", valid),
            ("refs/missing-default.usda", missingDefault),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.compactMap(\.primPath).sorted() == ["/Scene/Local", "/Scene/Valid"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderRejectsReferenceCycleWithLayerOffset() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Loop"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Loop" (
            references = @./root.usda@</Loop> (offset = 1; scale = 1)
        )
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
        ], alignPayloads: true)

        do {
            _ = try USDZReader().read(from: package)
            Issue.record("Expected reference cycle to fail.")
        } catch USDError.invalidData(let message) {
            #expect(message.contains("cycle"))
        } catch {
            Issue.record("Expected USDError.invalidData, got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderRejectsPayloadCycleWithLayerOffset() throws {
        let root = Data("""
        #usda 1.0
        (
            defaultPrim = "Loop"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Loop" (
            payload = @./root.usda@</Loop> (offset = 1; scale = 1)
        )
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usda", root),
        ], alignPayloads: true)

        do {
            _ = try USDZReader().read(from: package)
            Issue.record("Expected payload cycle to fail.")
        } catch USDError.invalidData(let message) {
            #expect(message.contains("cycle"))
        } catch {
            Issue.record("Expected USDError.invalidData, got \(error).")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderTraversesUSDCReferences() throws {
        let package = makeUSDZFixture(entries: [
            ("root.usdc", makeUSDCReferenceLayerFixture(assetPath: "assets/ref.usda")),
            ("assets/ref.usda", makeUSDAMeshLayer(name: "Triangle")),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.upAxis == .z)
        #expect(scene.meshes.map(\.name) == ["Scope"])
        #expect(scene.meshes.map(\.primPath) == ["/Scope"])
        #expect(scene.meshes.first?.points.count == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderUsesUSDCDefaultPrimForEmptyReferenceTarget() throws {
        let referencedLayer = Data("""
        #usda 1.0
        (
            defaultPrim = "Keep"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Keep"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }

        def Mesh "Drop"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usdc", makeUSDCReferenceLayerFixture(assetPath: "assets/meshes.usda", primPathIndex: 0)),
            ("assets/meshes.usda", referencedLayer),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package)

        #expect(scene.meshes.map(\.name) == ["Scope"])
        #expect(scene.meshes.map(\.primPath) == ["/Scope"])
        #expect(scene.meshes.first?.points == [
            USDPoint3D(x: 0, y: 0, z: 0),
            USDPoint3D(x: 1, y: 0, z: 0),
            USDPoint3D(x: 0, y: 1, z: 0),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderDoesNotMaterializeUSDCReferenceWithoutDefaultPrimTarget() throws {
        let referencedLayer = Data("""
        #usda 1.0
        (
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "LeakedA"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }

        def Mesh "LeakedB"
        {
            point3f[] points = [(0, 0, 1), (1, 0, 1), (0, 1, 1)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("root.usdc", makeUSDCReferenceLayerFixture(assetPath: "assets/meshes.usda", primPathIndex: 0)),
            ("assets/meshes.usda", referencedLayer),
        ], alignPayloads: true)

        #expect(throws: USDError.self) {
            _ = try USDZReader().read(from: package)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsFixtureBackedSubLayerGraph() throws {
        let package = try makeOpenUSDUSDSiblingPackage(root: "sublayers.usda")

        let graph = try USDZReader().readLayerGraph(from: package)

        #expect(graph.rootPath == "sublayers.usda")
        #expect(graph.paths == [
            "sublayers.usda",
            "single_usd.usdz[test.usd]",
            "single_usda.usdz[test.usda]",
            "single_usdc.usdz[test.usdc]",
        ])
        #expect(graph.layers.first?.composition.sublayerAssetPaths == [
            "./single_usd.usdz",
            "./single_usda.usdz",
            "./single_usdc.usdz",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsFixtureBackedReferenceGraph() throws {
        let package = try makeOpenUSDUSDSiblingPackage(root: "refs.usda")

        let graph = try USDZReader().readLayerGraph(from: package)

        #expect(graph.rootPath == "refs.usda")
        #expect(graph.paths == [
            "refs.usda",
            "single_usd.usdz[test.usd]",
            "single_usda.usdz[test.usda]",
            "single_usdc.usdz[test.usdc]",
        ])
        #expect(graph.layers.first?.composition.references == [
            USDCompositionArc(
                assetPath: "./single_usd.usdz",
                sitePrimPath: "/Refs",
                targetPrimPath: "/Root_USD"
            ),
            USDCompositionArc(
                assetPath: "./single_usda.usdz",
                sitePrimPath: "/Refs",
                targetPrimPath: "/Root_USDA"
            ),
            USDCompositionArc(
                assetPath: "./single_usdc.usdz",
                sitePrimPath: "/Refs",
                targetPrimPath: "/Root_USDC"
            ),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsNestedDefaultReferenceGraph() throws {
        let package = try openUSDFixture("testUsdUsdzFileFormat/nested_anchored_refs.usdz")

        let graph = try USDZReader().readLayerGraph(from: package)

        #expect(graph.rootPath == "anchored_refs.usdz[root.usd]")
        #expect(graph.paths == [
            "anchored_refs.usdz[root.usd]",
            "anchored_refs.usdz[ref.usd]",
            "anchored_refs.usdz[sub/ref.usda]",
            "anchored_refs.usdz[sub/ref.usdc]",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsNestedSearchReferenceGraph() throws {
        let package = try openUSDFixture("testUsdUsdzFileFormat/nested_search_refs.usdz")

        let graph = try USDZReader().readLayerGraph(from: package)

        #expect(graph.rootPath == "search_refs.usdz[root.usd]")
        #expect(graph.paths == [
            "search_refs.usdz[root.usd]",
            "search_refs.usdz[refs/ref.usd]",
            "search_refs.usdz[refs/sub/ref_in_subdir.usd]",
            "search_refs.usdz[sub/ref_in_root.usd]",
            "search_refs.usdz[refs/sub/ref_in_both.usd]",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsAnchoredReferenceGraphsFromOpenUSDFixtures() throws {
        let cases: [(fixture: String, rootPath: String, paths: [String])] = [
            (
                fixture: "testUsdUsdzFileFormat/anchored_refs.usdz",
                rootPath: "root.usd",
                paths: [
                    "root.usd",
                    "ref.usd",
                    "sub/ref.usda",
                    "sub/ref.usdc",
                ]
            ),
            (
                fixture: "testUsdUsdzFileFormat/anchored_refs_sub.usdz",
                rootPath: "anchored_refs/root.usd",
                paths: [
                    "anchored_refs/root.usd",
                    "anchored_refs/ref.usd",
                    "anchored_refs/sub/ref.usda",
                    "anchored_refs/sub/ref.usdc",
                ]
            ),
        ]

        for testCase in cases {
            let package = try openUSDFixture(testCase.fixture)

            let graph = try USDZReader().readLayerGraph(from: package)

            #expect(graph.rootPath == testCase.rootPath)
            #expect(graph.paths == testCase.paths)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsSearchReferenceGraphsFromOpenUSDFixtures() throws {
        let cases: [(fixture: String, rootPath: String, paths: [String])] = [
            (
                fixture: "testUsdUsdzFileFormat/search_refs.usdz",
                rootPath: "root.usd",
                paths: [
                    "root.usd",
                    "refs/ref.usd",
                    "refs/sub/ref_in_subdir.usd",
                    "sub/ref_in_root.usd",
                    "refs/sub/ref_in_both.usd",
                ]
            ),
            (
                fixture: "testUsdUsdzFileFormat/search_refs_sub.usdz",
                rootPath: "search_refs/root.usd",
                paths: [
                    "search_refs/root.usd",
                    "search_refs/refs/ref.usd",
                    "search_refs/refs/sub/ref_in_subdir.usd",
                    "search_refs/sub/ref_in_root.usd",
                    "search_refs/refs/sub/ref_in_both.usd",
                ]
            ),
        ]

        for testCase in cases {
            let package = try openUSDFixture(testCase.fixture)

            let graph = try USDZReader().readLayerGraph(from: package)

            #expect(graph.rootPath == testCase.rootPath)
            #expect(graph.paths == testCase.paths)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsNestedSubdirectoryReferenceGraphsFromOpenUSDFixtures() throws {
        let cases: [(fixture: String, rootPath: String, paths: [String])] = [
            (
                fixture: "testUsdUsdzFileFormat/nested_anchored_refs_sub.usdz",
                rootPath: "anchored_refs_sub.usdz[anchored_refs/root.usd]",
                paths: [
                    "anchored_refs_sub.usdz[anchored_refs/root.usd]",
                    "anchored_refs_sub.usdz[anchored_refs/ref.usd]",
                    "anchored_refs_sub.usdz[anchored_refs/sub/ref.usda]",
                    "anchored_refs_sub.usdz[anchored_refs/sub/ref.usdc]",
                ]
            ),
            (
                fixture: "testUsdUsdzFileFormat/nested_search_refs_sub.usdz",
                rootPath: "search_refs_sub.usdz[search_refs/root.usd]",
                paths: [
                    "search_refs_sub.usdz[search_refs/root.usd]",
                    "search_refs_sub.usdz[search_refs/refs/ref.usd]",
                    "search_refs_sub.usdz[search_refs/refs/sub/ref_in_subdir.usd]",
                    "search_refs_sub.usdz[search_refs/sub/ref_in_root.usd]",
                    "search_refs_sub.usdz[search_refs/refs/sub/ref_in_both.usd]",
                ]
            ),
        ]

        for testCase in cases {
            let package = try openUSDFixture(testCase.fixture)

            let graph = try USDZReader().readLayerGraph(from: package)

            #expect(graph.rootPath == testCase.rootPath)
            #expect(graph.paths == testCase.paths)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderReadsSpecificLayerGraphsFromOpenUSDLayerPaths() throws {
        let cases: [(fixture: String, rootPath: String, expectedRootPath: String, paths: [String])] = [
            (
                fixture: "testUsdUsdzFileFormat/anchored_refs.usdz",
                rootPath: "sub/ref.usda",
                expectedRootPath: "sub/ref.usda",
                paths: [
                    "sub/ref.usda",
                ]
            ),
            (
                fixture: "testUsdUsdzFileFormat/nested_anchored_refs.usdz",
                rootPath: "anchored_refs.usdz",
                expectedRootPath: "anchored_refs.usdz[root.usd]",
                paths: [
                    "anchored_refs.usdz[root.usd]",
                    "anchored_refs.usdz[ref.usd]",
                    "anchored_refs.usdz[sub/ref.usda]",
                    "anchored_refs.usdz[sub/ref.usdc]",
                ]
            ),
            (
                fixture: "testUsdUsdzFileFormat/nested_anchored_refs.usdz",
                rootPath: "anchored_refs.usdz[root.usd]",
                expectedRootPath: "anchored_refs.usdz[root.usd]",
                paths: [
                    "anchored_refs.usdz[root.usd]",
                    "anchored_refs.usdz[ref.usd]",
                    "anchored_refs.usdz[sub/ref.usda]",
                    "anchored_refs.usdz[sub/ref.usdc]",
                ]
            ),
            (
                fixture: "testUsdUsdzFileFormat/nested_anchored_refs.usdz",
                rootPath: "anchored_refs.usdz[sub/ref.usda]",
                expectedRootPath: "anchored_refs.usdz[sub/ref.usda]",
                paths: [
                    "anchored_refs.usdz[sub/ref.usda]",
                ]
            ),
        ]

        for testCase in cases {
            let package = try openUSDFixture(testCase.fixture)

            let graph = try USDZReader().readLayerGraph(from: package, rootLayerPath: testCase.rootPath)

            #expect(graph.rootPath == testCase.expectedRootPath)
            #expect(graph.paths == testCase.paths)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderMaterializesSpecificLayerPathScene() throws {
        let package = makeUSDZFixture(entries: [
            ("root.usda", Data("#usda 1.0\n".utf8)),
            ("meshes/triangle.usda", makeUSDAMeshLayer(name: "Triangle")),
        ], alignPayloads: true)

        let scene = try USDZReader().read(from: package, rootLayerPath: "meshes/triangle.usda")

        #expect(scene.meshes.map(\.name) == ["Triangle"])
        #expect(scene.meshes.first?.faceVertexIndices == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdzReaderRejectsUnalignedPayload() throws {
        let usda = Data("""
        #usda 1.0
        (
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "Triangle"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
        }
        """.utf8)
        let package = makeUSDZFixture(entries: [
            ("scene.usda", usda),
        ], alignPayloads: false)

        #expect(throws: USDError.self) {
            _ = try USDZArchive(data: package)
        }
    }
}

func makeUSDCFixture(
    version: USDCCrateVersion = USDCCrateVersion(major: 0, minor: 8, patch: 0),
    valueData: Data = Data(),
    sections: [(String, Data)]
) -> Data {
    var offset = USDCCrateFile.bootstrapByteCount + valueData.count
    let sectionRanges = sections.map { section -> (name: String, start: Int, size: Int, data: Data) in
        let start = offset
        offset += section.1.count
        return (section.0, start, section.1.count, section.1)
    }
    let tableOfContentsOffset = offset

    var data = Data()
    data.append(contentsOf: USDCReader.fileSignature)
    data.append(contentsOf: [version.major, version.minor, version.patch, 0, 0, 0, 0, 0])
    data.appendLittleEndian(Int64(tableOfContentsOffset))
    for _ in 0..<8 {
        data.appendLittleEndian(Int64(0))
    }
    data.append(valueData)
    for section in sectionRanges {
        data.append(section.data)
    }
    data.appendLittleEndian(UInt64(sectionRanges.count))
    for section in sectionRanges {
        data.appendFixedASCII(section.name, byteCount: 16)
        data.appendLittleEndian(Int64(section.start))
        data.appendLittleEndian(Int64(section.size))
    }
    return data
}

private func expectPointsApproximatelyEqual(
    _ actual: [USDPoint3D],
    _ expected: [USDPoint3D],
    tolerance: Double = 1e-9
) {
    #expect(actual.count == expected.count)
    for index in 0..<min(actual.count, expected.count) {
        #expect(abs(actual[index].x - expected[index].x) <= tolerance)
        #expect(abs(actual[index].y - expected[index].y) <= tolerance)
        #expect(abs(actual[index].z - expected[index].z) <= tolerance)
    }
}

private func makeUSDAMeshLayer(name: String) -> Data {
    Data("""
    #usda 1.0
    (
        defaultPrim = "\(name)"
        metersPerUnit = 1
        upAxis = "Z"
    )

    def Mesh "\(name)"
    {
        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        uniform token subdivisionScheme = "none"
    }
    """.utf8)
}

private func makeUSDCLayerTokenVectorFixture() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "specifier",
        "typeName",
        "Scope",
        "properties",
        "firstProperty",
        "secondProperty",
    ]
    var valueData = Data()
    let propertiesOffset = appendUSDCTokenVector([4, 5], to: &valueData)
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 1,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 2)
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .tokenVector, isInlined: false, isArray: false, payload: propertiesOffset)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, 1, 2, UInt32.max,
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

private func makeUSDCLayerAssetPathAndPathVectorFixture() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "specifier",
        "Scope",
        "assetPath",
        "pathVector",
        "assets/model.usda",
    ]
    var valueData = Data()
    let assetPathOffset = appendUSDCStringIndex(0, to: &valueData)
    let pathVectorOffset = appendUSDCPathVector([0, 1], to: &valueData)
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 2,
            valueRep: USDCCrateValueRep(type: .assetPath, isInlined: false, isArray: false, payload: assetPathOffset)
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .pathVector, isInlined: false, isArray: false, payload: pathVectorOffset)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([4])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, 1, 2, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 2,
            pathIndexes: [0, 1],
            elementTokenIndexes: [0, 1],
            jumps: [-1, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCLayerMetadataFieldFixture() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 9, patch: 0)
    let tokens = [
        "specifier",
        "Scope",
        "subLayers",
        "subLayerOffsets",
        "variantSelections",
        "permission",
        "variability",
        "timeCodeValue",
        "timeCodeArray",
        "stringVector",
        "doubleVector",
        "dictionaryValue",
        "unsupportedMatrix2d",
        "unknownRawValue",
        "layers/base.usda",
        "layers/anim.usdc",
        "modelingVariant",
        "high",
        "lod",
        "render",
        "alpha",
        "beta",
    ]
    var valueData = Data()
    let subLayersOffset = appendUSDCStringVector([0, 1], to: &valueData)
    let subLayerOffsetsOffset = appendUSDCLayerOffsetVector([
        SdfLayerOffset(offset: 10, scale: 0.5),
        .identity,
    ], to: &valueData)
    let variantSelectionMapOffset = appendUSDCVariantSelectionMap([
        USDCEncodedStringMapEntry(keyStringIndex: 2, valueStringIndex: 3),
        USDCEncodedStringMapEntry(keyStringIndex: 4, valueStringIndex: 5),
    ], to: &valueData)
    let timeCodeValueOffset = appendUSDCDoubleScalar(24, to: &valueData)
    let timeCodeArrayOffset = appendUSDCDoubleArray([1, 2.5], to: &valueData)
    let stringVectorOffset = appendUSDCStringVector([6, 7], to: &valueData)
    let doubleVectorOffset = appendUSDCDoubleVector([1.25, 2.5], to: &valueData)
    let unknownRawValue = USDCCrateValueRep(
        rawValue: USDCCrateValueRep.isArrayBit
            | USDCCrateValueRep.isInlinedBit
            | USDCCrateValueRep.isCompressedBit
            | USDCCrateValueRep.isArrayEditBit
            | (UInt64(250) << 48)
            | 456
    )
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 2,
            valueRep: USDCCrateValueRep(type: .stringVector, isInlined: false, isArray: false, payload: subLayersOffset)
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .layerOffsetVector, isInlined: false, isArray: false, payload: subLayerOffsetsOffset)
        ),
        USDCCrateField(
            tokenIndex: 4,
            valueRep: USDCCrateValueRep(type: .variantSelectionMap, isInlined: false, isArray: false, payload: variantSelectionMapOffset)
        ),
        USDCCrateField(
            tokenIndex: 5,
            valueRep: USDCCrateValueRep(type: .permission, isInlined: true, isArray: false, payload: UInt64(SdfPermission.privateAccess.rawValue))
        ),
        USDCCrateField(
            tokenIndex: 6,
            valueRep: USDCCrateValueRep(type: .variability, isInlined: true, isArray: false, payload: 2)
        ),
        USDCCrateField(
            tokenIndex: 7,
            valueRep: USDCCrateValueRep(type: .timeCode, isInlined: false, isArray: false, payload: timeCodeValueOffset)
        ),
        USDCCrateField(
            tokenIndex: 8,
            valueRep: USDCCrateValueRep(type: .timeCode, isInlined: false, isArray: true, payload: timeCodeArrayOffset)
        ),
        USDCCrateField(
            tokenIndex: 9,
            valueRep: USDCCrateValueRep(type: .stringVector, isInlined: false, isArray: false, payload: stringVectorOffset)
        ),
        USDCCrateField(
            tokenIndex: 10,
            valueRep: USDCCrateValueRep(type: .doubleVector, isInlined: false, isArray: false, payload: doubleVectorOffset)
        ),
        USDCCrateField(
            tokenIndex: 11,
            valueRep: USDCCrateValueRep(type: .dictionary, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(type: .matrix2d, isInlined: true, isArray: false, payload: 123)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: unknownRawValue
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 3, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([14, 15, 16, 17, 18, 19, 20, 21])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            1, 2, UInt32.max,
            0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 2,
            pathIndexes: [0, 1],
            elementTokenIndexes: [0, 1],
            jumps: [-1, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCLayerNumericFieldFixture(compressedArrays: Bool = false) -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "specifier",
        "Scope",
        "intValue",
        "vec2fValue",
        "vec2dValue",
        "doubleArray",
        "boolValue",
        "ucharValue",
        "uintValue",
        "int64Value",
        "uint64Value",
        "boolArray",
        "ucharArray",
        "uintArray",
        "int64Array",
        "uint64Array",
    ]
    var valueData = Data()
    let vec2fOffset = appendUSDCVec2fScalar(USDPoint2D(x: 1.5, y: -2.25), to: &valueData)
    let vec2dOffset = appendUSDCVec2dScalar(USDPoint2D(x: 3.25, y: 4.5), to: &valueData)
    let doubleArrayOffset = appendUSDCDoubleArray([1.25, 2.5], compressed: compressedArrays, to: &valueData)
    let int64Offset = appendUSDCInt64Scalar(-84, to: &valueData)
    let uint64Offset = appendUSDCUInt64Scalar(84, to: &valueData)
    let boolArrayOffset = appendUSDCBoolArray([true, false, true], compressed: compressedArrays, to: &valueData)
    let ucharArrayOffset = appendUSDCUInt8Array([1, 255], compressed: compressedArrays, to: &valueData)
    let uintArrayOffset = appendUSDCUInt32Array([42, 84], compressed: compressedArrays, to: &valueData)
    let int64ArrayOffset = appendUSDCInt64Array([-84, 168], compressed: compressedArrays, to: &valueData)
    let uint64ArrayOffset = appendUSDCUInt64Array([84, 168], compressed: compressedArrays, to: &valueData)
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 2,
            valueRep: USDCCrateValueRep(
                type: .int,
                isInlined: true,
                isArray: false,
                payload: UInt64(UInt32(bitPattern: Int32(-42)))
            )
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .vec2f, isInlined: false, isArray: false, payload: vec2fOffset)
        ),
        USDCCrateField(
            tokenIndex: 4,
            valueRep: USDCCrateValueRep(type: .vec2d, isInlined: false, isArray: false, payload: vec2dOffset)
        ),
        USDCCrateField(
            tokenIndex: 5,
            valueRep: arrayValueRep(type: .double, payload: doubleArrayOffset, compressed: compressedArrays)
        ),
        USDCCrateField(
            tokenIndex: 6,
            valueRep: USDCCrateValueRep(type: .bool, isInlined: true, isArray: false, payload: 1)
        ),
        USDCCrateField(
            tokenIndex: 7,
            valueRep: USDCCrateValueRep(type: .uChar, isInlined: true, isArray: false, payload: 255)
        ),
        USDCCrateField(
            tokenIndex: 8,
            valueRep: USDCCrateValueRep(type: .uInt, isInlined: true, isArray: false, payload: 42)
        ),
        USDCCrateField(
            tokenIndex: 9,
            valueRep: USDCCrateValueRep(type: .int64, isInlined: false, isArray: false, payload: int64Offset)
        ),
        USDCCrateField(
            tokenIndex: 10,
            valueRep: USDCCrateValueRep(type: .uInt64, isInlined: false, isArray: false, payload: uint64Offset)
        ),
        USDCCrateField(
            tokenIndex: 11,
            valueRep: arrayValueRep(type: .bool, payload: boolArrayOffset, compressed: compressedArrays)
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: arrayValueRep(type: .uChar, payload: ucharArrayOffset, compressed: compressedArrays)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: arrayValueRep(type: .uInt, payload: uintArrayOffset, compressed: compressedArrays)
        ),
        USDCCrateField(
            tokenIndex: 14,
            valueRep: arrayValueRep(type: .int64, payload: int64ArrayOffset, compressed: compressedArrays)
        ),
        USDCCrateField(
            tokenIndex: 15,
            valueRep: arrayValueRep(type: .uInt64, payload: uint64ArrayOffset, compressed: compressedArrays)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            10, 11, 12, 13, 14, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 2,
            pathIndexes: [0, 1],
            elementTokenIndexes: [0, 1],
            jumps: [-1, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCLayerListOperationFixture() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "specifier",
        "Scope",
        "target",
        "tokenListOperation",
        "stringListOperation",
        "pathListOperation",
        "tokenExplicit",
        "tokenAdded",
        "tokenPrepended",
        "tokenAppended",
        "tokenDeleted",
        "tokenOrdered",
        "stringAdded",
    ]
    var valueData = Data()
    let tokenListOperationOffset = appendUSDCIndexedListOperation(
        isExplicit: true,
        explicitItems: [6],
        addedItems: [7],
        prependedItems: [8],
        appendedItems: [9],
        deletedItems: [10],
        orderedItems: [11],
        to: &valueData
    )
    let stringListOperationOffset = appendUSDCIndexedListOperation(
        isExplicit: true,
        addedItems: [0],
        to: &valueData
    )
    let pathListOperationOffset = appendUSDCIndexedListOperation(
        prependedItems: [0],
        appendedItems: [2],
        deletedItems: [1],
        orderedItems: [2],
        to: &valueData
    )
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .tokenListOperation, isInlined: false, isArray: false, payload: tokenListOperationOffset)
        ),
        USDCCrateField(
            tokenIndex: 4,
            valueRep: USDCCrateValueRep(type: .stringListOperation, isInlined: false, isArray: false, payload: stringListOperationOffset)
        ),
        USDCCrateField(
            tokenIndex: 5,
            valueRep: USDCCrateValueRep(type: .pathListOperation, isInlined: false, isArray: false, payload: pathListOperationOffset)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([12])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, 1, 2, 3, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 3,
            pathIndexes: [0, 1, 2],
            elementTokenIndexes: [0, 1, -2],
            jumps: [-1, -1, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCLayerCompositionArcFixture() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "specifier",
        "Scope",
        "target",
        "references",
        "payload",
        "singlePayload",
        "PayloadTarget",
        "assets/ref.usda",
        "assets/payload.usdc",
        "assets/single.usda",
        "referencePurpose",
        "render",
        "displayName",
        "friendlyRef",
        "assets/second.usda",
    ]
    var valueData = Data()
    let referenceListOperationOffset = appendUSDCReferenceListOperation(
        addedItems: [
            USDCEncodedReference(
                assetPathStringIndex: 0,
                primPathIndex: 2,
                layerOffset: SdfLayerOffset(offset: 1.5, scale: 2),
                customData: [
                    USDCEncodedDictionaryEntry(
                        keyStringIndex: 3,
                        valueRep: USDCCrateValueRep(type: .string, isInlined: true, isArray: false, payload: 4)
                    ),
                    USDCEncodedDictionaryEntry(
                        keyStringIndex: 5,
                        valueRep: USDCCrateValueRep(type: .string, isInlined: false, isArray: false, payload: 0),
                        nestedPayload: littleEndianData(UInt32(6)),
                        usesNestedPayloadOffset: true
                    ),
                ]
            ),
            USDCEncodedReference(
                assetPathStringIndex: 7,
                primPathIndex: 2,
                layerOffset: .identity
            ),
        ],
        deletedItems: [
            USDCEncodedReference(
                assetPathStringIndex: 7,
                primPathIndex: 2,
                layerOffset: .identity
            ),
        ],
        orderedItems: [
            USDCEncodedReference(
                assetPathStringIndex: 0,
                primPathIndex: 2,
                layerOffset: SdfLayerOffset(offset: 1.5, scale: 2),
                customData: [
                    USDCEncodedDictionaryEntry(
                        keyStringIndex: 3,
                        valueRep: USDCCrateValueRep(type: .string, isInlined: true, isArray: false, payload: 4)
                    ),
                    USDCEncodedDictionaryEntry(
                        keyStringIndex: 5,
                        valueRep: USDCCrateValueRep(type: .string, isInlined: false, isArray: false, payload: 0),
                        nestedPayload: littleEndianData(UInt32(6)),
                        usesNestedPayloadOffset: true
                    ),
                ]
            ),
        ],
        to: &valueData
    )
    let payloadListOperationOffset = appendUSDCPayloadListOperation(
        prependedItems: [
            USDCEncodedPayload(
                assetPathStringIndex: 1,
                primPathIndex: 3,
                layerOffset: SdfLayerOffset(offset: -2, scale: 0.5)
            ),
        ],
        to: &valueData
    )
    let payloadOffset = appendUSDCPayload(
        USDCEncodedPayload(
            assetPathStringIndex: 2,
            primPathIndex: 1,
            layerOffset: .identity
        ),
        to: &valueData
    )
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .referenceListOperation, isInlined: false, isArray: false, payload: referenceListOperationOffset)
        ),
        USDCCrateField(
            tokenIndex: 4,
            valueRep: USDCCrateValueRep(type: .payloadListOperation, isInlined: false, isArray: false, payload: payloadListOperationOffset)
        ),
        USDCCrateField(
            tokenIndex: 5,
            valueRep: USDCCrateValueRep(type: .payload, isInlined: false, isArray: false, payload: payloadOffset)
        ),
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 1, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([7, 8, 9, 10, 11, 12, 13, 14])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            UInt32.max,
            0, 1, 2, 3, UInt32.max,
        ])),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 4,
            pathIndexes: [0, 1, 2, 3],
            elementTokenIndexes: [0, 1, -2, 6],
            jumps: [-1, 2, -2, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCReferenceLayerFixture(assetPath: String, primPathIndex: UInt32 = 2) -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "specifier",
        "Scope",
        "references",
        assetPath,
        "Triangle",
    ]
    var valueData = Data()
    let referenceListOperationOffset = appendUSDCReferenceListOperation(
        addedItems: [
            USDCEncodedReference(
                assetPathStringIndex: 0,
                primPathIndex: primPathIndex,
                layerOffset: .identity
            ),
        ],
        to: &valueData
    )
    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 2,
            valueRep: USDCCrateValueRep(type: .referenceListOperation, isInlined: false, isArray: false, payload: referenceListOperationOffset)
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
            pathCount: 3,
            pathIndexes: [0, 1, 2],
            elementTokenIndexes: [0, 1, 4],
            jumps: [-1, 0, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCResetSubrootMeshLayerFixture() -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let tokens = [
        "defaultPrim",
        "Model",
        "Geom",
        "metersPerUnit",
        "upAxis",
        "Z",
        "specifier",
        "typeName",
        "Mesh",
        "faceVertexCounts",
        "faceVertexIndices",
        "points",
        "subdivisionScheme",
        "default",
        "none",
        "xformOp:translate",
        "xformOpOrder",
        "!resetXformStack!",
    ]
    var valueData = Data()
    let faceVertexCountsOffset = appendUSDCIntArray([3], to: &valueData)
    let faceVertexIndicesOffset = appendUSDCIntArray([0, 1, 2], to: &valueData)
    let pointsOffset = appendUSDCVec3fArray([
        USDPoint3D(x: 0, y: 0, z: 0),
        USDPoint3D(x: 1, y: 0, z: 0),
        USDPoint3D(x: 0, y: 1, z: 0),
    ], to: &valueData)
    let modelTranslateOffset = appendUSDCVec3dScalar(USDPoint3D(x: 100, y: 0, z: 0), to: &valueData)
    let modelXformOpOrderOffset = appendUSDCTokenArray([15], compressed: false, to: &valueData)
    let geomTranslateOffset = appendUSDCVec3dScalar(USDPoint3D(x: 0, y: 5, z: 0), to: &valueData)
    let geomXformOpOrderOffset = appendUSDCTokenArray([17, 15], compressed: false, to: &valueData)

    let fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 1)
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .double, isInlined: true, isArray: false, payload: UInt64(Float32(1).bitPattern))
        ),
        USDCCrateField(
            tokenIndex: 4,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 5)
        ),
        USDCCrateField(
            tokenIndex: 6,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 7,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 8)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexCountsOffset)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexIndicesOffset)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .vec3f, isInlined: false, isArray: true, payload: pointsOffset)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 14)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .vec3d, isInlined: false, isArray: false, payload: modelTranslateOffset)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .token, isInlined: false, isArray: true, payload: modelXformOpOrderOffset)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .vec3d, isInlined: false, isArray: false, payload: geomTranslateOffset)
        ),
        USDCCrateField(
            tokenIndex: 13,
            valueRep: USDCCrateValueRep(type: .token, isInlined: false, isArray: true, payload: geomXformOpOrderOffset)
        ),
    ]

    var fieldSetIndexes: [UInt32] = []
    func appendFieldSet(_ indexes: [UInt32]) -> UInt32 {
        let fieldSetIndex = UInt32(fieldSetIndexes.count)
        fieldSetIndexes.append(contentsOf: indexes)
        fieldSetIndexes.append(UInt32.max)
        return fieldSetIndex
    }

    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: appendFieldSet([0, 1, 2]), specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: appendFieldSet([3]), specType: .prim),
        USDCCrateSpec(pathIndex: 2, fieldSetIndex: appendFieldSet([3, 4]), specType: .prim),
        USDCCrateSpec(pathIndex: 3, fieldSetIndex: appendFieldSet([5]), specType: .attribute),
        USDCCrateSpec(pathIndex: 4, fieldSetIndex: appendFieldSet([6]), specType: .attribute),
        USDCCrateSpec(pathIndex: 5, fieldSetIndex: appendFieldSet([7]), specType: .attribute),
        USDCCrateSpec(pathIndex: 6, fieldSetIndex: appendFieldSet([8]), specType: .attribute),
        USDCCrateSpec(pathIndex: 7, fieldSetIndex: appendFieldSet([11]), specType: .attribute),
        USDCCrateSpec(pathIndex: 8, fieldSetIndex: appendFieldSet([12]), specType: .attribute),
        USDCCrateSpec(pathIndex: 9, fieldSetIndex: appendFieldSet([9]), specType: .attribute),
        USDCCrateSpec(pathIndex: 10, fieldSetIndex: appendFieldSet([10]), specType: .attribute),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: fieldSetIndexes)),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: 11,
            pathIndexes: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            elementTokenIndexes: [0, 1, 2, -9, -10, -11, -12, -15, -16, -15, -16],
            jumps: [-1, -1, 7, 0, 0, 0, 0, 0, -2, 0, -2]
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func makeUSDCMeshSceneFixture(
    compressedPoints: Bool = false,
    faceVertexCounts: [Int32] = [3],
    faceVertexIndices: [Int32] = [0, 1, 2],
    compressedXformOpOrder: Bool = false,
    translateTimeSamples: [(timeCode: Double, value: USDPoint3D)]? = nil,
    matrixTransformTimeSamples: [(timeCode: Double, values: [Double])]? = nil,
    includeExtent: Bool = false,
    extentTimeSamples: [(timeCode: Double, points: [USDPoint3D])]? = nil,
    textureCoordinateTimeSamples: [(timeCode: Double, values: [USDPoint2D])]? = nil,
    displayOpacityTimeSamples: [(timeCode: Double, values: [Double])]? = nil,
    blockedTopologyTimeSampleField: String? = nil,
    sampledTopologyTimeSampleField: String? = nil,
    sampledTopologyTimeSampleValues: [Int32] = [],
    valueBlockedTopologyDefaultField: String? = nil,
    meshSpecifierPayload: UInt64 = 0
) -> Data {
    precondition(translateTimeSamples == nil || matrixTransformTimeSamples == nil)
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
    let xformOpToken = matrixTransformTimeSamples == nil ? "xformOp:translate" : "xformOp:transform"
    let tokens = [
        "defaultPrim",
        "Triangle",
        "metersPerUnit",
        "upAxis",
        "Z",
        "specifier",
        "typeName",
        "Mesh",
        "faceVertexCounts",
        "faceVertexIndices",
        "points",
        "subdivisionScheme",
        "default",
        "none",
        xformOpToken,
        "xformOpOrder",
        "extent",
        "timeSamples",
        "primvars:st",
        "primvars:displayOpacity",
    ]
    var valueData = Data()
    let faceVertexCountsOffset = appendUSDCIntArray(faceVertexCounts, to: &valueData)
    let faceVertexIndicesOffset = appendUSDCIntArray(faceVertexIndices, to: &valueData)
    let meshPoints = [
        USDPoint3D(x: 0, y: 0, z: 0),
        USDPoint3D(x: 1, y: 0, z: 0),
        USDPoint3D(x: 0, y: 1, z: 0),
    ]
    let pointsOffset: UInt64
    if compressedPoints {
        pointsOffset = appendUSDCCompressedVec3fArray(meshPoints, to: &valueData)
    } else {
        pointsOffset = appendUSDCVec3fArray(meshPoints, to: &valueData)
    }
    var pointsValueRep = USDCCrateValueRep(type: .vec3f, isInlined: false, isArray: true, payload: pointsOffset)
    if compressedPoints {
        pointsValueRep.rawValue |= USDCCrateValueRep.isCompressedBit
    }
    let xformOffset: UInt64?
    let xformOpOrderOffset: UInt64?
    let xformDefaultValueType: USDCCrateValueType
    if compressedXformOpOrder || translateTimeSamples != nil || matrixTransformTimeSamples != nil {
        if matrixTransformTimeSamples == nil {
            xformOffset = appendUSDCVec3dScalar(USDPoint3D(x: 2, y: 3, z: 4), to: &valueData)
            xformDefaultValueType = .vec3d
        } else {
            xformOffset = appendUSDCMatrix4dScalar([
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                2, 3, 4, 1,
            ], to: &valueData)
            xformDefaultValueType = .matrix4d
        }
        xformOpOrderOffset = appendUSDCTokenArray([14], compressed: true, to: &valueData)
    } else {
        xformOffset = nil
        xformDefaultValueType = .vec3d
        xformOpOrderOffset = nil
    }
    let extentField: (tokenIndex: UInt32, valueRep: USDCCrateValueRep)?
    if let extentTimeSamples {
        let sampleValueReps = extentTimeSamples.map { sample in
            USDCCrateValueRep(
                type: .vec3f,
                isInlined: false,
                isArray: true,
                payload: appendUSDCVec3fArray(sample.points, to: &valueData)
            )
        }
        let extentTimeSamplesOffset = appendUSDCTimeSamples(
            times: extentTimeSamples.map { $0.timeCode },
            valueReps: sampleValueReps,
            to: &valueData
        )
        extentField = (
            tokenIndex: 17,
            valueRep: USDCCrateValueRep(
                type: .timeSamples,
                isInlined: false,
                isArray: false,
                payload: extentTimeSamplesOffset
            )
        )
    } else if includeExtent {
        extentField = (
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(
                type: .vec3f,
                isInlined: false,
                isArray: true,
                payload: appendUSDCVec3fArray([
                    USDPoint3D(x: 0, y: 0, z: 0),
                    USDPoint3D(x: 1, y: 1, z: 0),
                ], to: &valueData)
            )
        )
    } else {
        extentField = nil
    }

    let faceVertexCountsDefaultValueRep = valueBlockedTopologyDefaultField == "faceVertexCounts"
        ? USDCCrateValueRep(type: .valueBlock, isInlined: false, isArray: false, payload: 0)
        : USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexCountsOffset)
    let faceVertexIndicesDefaultValueRep = valueBlockedTopologyDefaultField == "faceVertexIndices"
        ? USDCCrateValueRep(type: .valueBlock, isInlined: false, isArray: false, payload: 0)
        : USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexIndicesOffset)

    var fields = [
        USDCCrateField(
            tokenIndex: 0,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 1)
        ),
        USDCCrateField(
            tokenIndex: 2,
            valueRep: USDCCrateValueRep(type: .double, isInlined: true, isArray: false, payload: UInt64(Float32(1).bitPattern))
        ),
        USDCCrateField(
            tokenIndex: 3,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 4)
        ),
        USDCCrateField(
            tokenIndex: 5,
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: meshSpecifierPayload)
        ),
        USDCCrateField(
            tokenIndex: 6,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 7)
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: faceVertexCountsDefaultValueRep
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: faceVertexIndicesDefaultValueRep
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: pointsValueRep
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 13)
        ),
    ]
    let xformFieldIndex: UInt32?
    let xformTimeSamplesFieldIndex: UInt32?
    let xformOpOrderFieldIndex: UInt32?
    if let xformOffset, let xformOpOrderOffset {
        xformFieldIndex = UInt32(fields.count)
        fields.append(USDCCrateField(
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(type: xformDefaultValueType, isInlined: false, isArray: false, payload: xformOffset)
        ))
        if let translateTimeSamples {
            let sampleValueReps = translateTimeSamples.map { sample in
                USDCCrateValueRep(
                    type: .vec3d,
                    isInlined: false,
                    isArray: false,
                    payload: appendUSDCVec3dScalar(sample.value, to: &valueData)
                )
            }
            let timeSamplesOffset = appendUSDCTimeSamples(
                times: translateTimeSamples.map(\.timeCode),
                valueReps: sampleValueReps,
                to: &valueData
            )
            xformTimeSamplesFieldIndex = UInt32(fields.count)
            fields.append(USDCCrateField(
                tokenIndex: 17,
                valueRep: USDCCrateValueRep(
                    type: .timeSamples,
                    isInlined: false,
                    isArray: false,
                    payload: timeSamplesOffset
                )
            ))
        } else if let matrixTransformTimeSamples {
            let sampleValueReps = matrixTransformTimeSamples.map { sample in
                USDCCrateValueRep(
                    type: .matrix4d,
                    isInlined: false,
                    isArray: false,
                    payload: appendUSDCMatrix4dScalar(sample.values, to: &valueData)
                )
            }
            let timeSamplesOffset = appendUSDCTimeSamples(
                times: matrixTransformTimeSamples.map(\.timeCode),
                valueReps: sampleValueReps,
                to: &valueData
            )
            xformTimeSamplesFieldIndex = UInt32(fields.count)
            fields.append(USDCCrateField(
                tokenIndex: 17,
                valueRep: USDCCrateValueRep(
                    type: .timeSamples,
                    isInlined: false,
                    isArray: false,
                    payload: timeSamplesOffset
                )
            ))
        } else {
            xformTimeSamplesFieldIndex = nil
        }
        var xformOpOrderValueRep = USDCCrateValueRep(type: .token, isInlined: false, isArray: true, payload: xformOpOrderOffset)
        xformOpOrderValueRep.rawValue |= USDCCrateValueRep.isCompressedBit
        xformOpOrderFieldIndex = UInt32(fields.count)
        fields.append(USDCCrateField(
            tokenIndex: 12,
            valueRep: xformOpOrderValueRep
        ))
    } else {
        xformFieldIndex = nil
        xformTimeSamplesFieldIndex = nil
        xformOpOrderFieldIndex = nil
    }
    let extentFieldIndex: UInt32?
    if let extentField {
        extentFieldIndex = UInt32(fields.count)
        fields.append(USDCCrateField(
            tokenIndex: extentField.tokenIndex,
            valueRep: extentField.valueRep
        ))
    } else {
        extentFieldIndex = nil
    }

    let textureCoordinateTimeSamplesFieldIndex: UInt32?
    if let textureCoordinateTimeSamples {
        let sampleValueReps = textureCoordinateTimeSamples.map { sample in
            USDCCrateValueRep(
                type: .vec2f,
                isInlined: false,
                isArray: true,
                payload: appendUSDCVec2fArray(sample.values, to: &valueData)
            )
        }
        let timeSamplesOffset = appendUSDCTimeSamples(
            times: textureCoordinateTimeSamples.map(\.timeCode),
            valueReps: sampleValueReps,
            to: &valueData
        )
        textureCoordinateTimeSamplesFieldIndex = UInt32(fields.count)
        fields.append(USDCCrateField(
            tokenIndex: 17,
            valueRep: USDCCrateValueRep(
                type: .timeSamples,
                isInlined: false,
                isArray: false,
                payload: timeSamplesOffset
            )
        ))
    } else {
        textureCoordinateTimeSamplesFieldIndex = nil
    }

    let displayOpacityTimeSamplesFieldIndex: UInt32?
    if let displayOpacityTimeSamples {
        let sampleValueReps = displayOpacityTimeSamples.map { sample in
            USDCCrateValueRep(
                type: .double,
                isInlined: false,
                isArray: true,
                payload: appendUSDCDoubleArray(sample.values, to: &valueData)
            )
        }
        let timeSamplesOffset = appendUSDCTimeSamples(
            times: displayOpacityTimeSamples.map(\.timeCode),
            valueReps: sampleValueReps,
            to: &valueData
        )
        displayOpacityTimeSamplesFieldIndex = UInt32(fields.count)
        fields.append(USDCCrateField(
            tokenIndex: 17,
            valueRep: USDCCrateValueRep(
                type: .timeSamples,
                isInlined: false,
                isArray: false,
                payload: timeSamplesOffset
            )
        ))
    } else {
        displayOpacityTimeSamplesFieldIndex = nil
    }

    let faceVertexCountsTimeSamplesFieldIndex = appendUSDCTopologyTimeSamplesField(
        named: "faceVertexCounts",
        blockedTopologyTimeSampleField: blockedTopologyTimeSampleField,
        sampledTopologyTimeSampleField: sampledTopologyTimeSampleField,
        sampledTopologyTimeSampleValues: sampledTopologyTimeSampleValues,
        fallbackValueRep: USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexCountsOffset),
        valueData: &valueData,
        fields: &fields
    )
    let faceVertexIndicesTimeSamplesFieldIndex = appendUSDCTopologyTimeSamplesField(
        named: "faceVertexIndices",
        blockedTopologyTimeSampleField: blockedTopologyTimeSampleField,
        sampledTopologyTimeSampleField: sampledTopologyTimeSampleField,
        sampledTopologyTimeSampleValues: sampledTopologyTimeSampleValues,
        fallbackValueRep: USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexIndicesOffset),
        valueData: &valueData,
        fields: &fields
    )

    var fieldSetIndexes: [UInt32] = []
    func appendFieldSet(_ indexes: [UInt32]) -> UInt32 {
        let fieldSetIndex = UInt32(fieldSetIndexes.count)
        fieldSetIndexes.append(contentsOf: indexes)
        fieldSetIndexes.append(UInt32.max)
        return fieldSetIndex
    }

    let rootFieldSetIndex = appendFieldSet([0, 1, 2])
    let meshFieldSetIndex = appendFieldSet([3, 4])
    var faceVertexCountsFieldIndexes: [UInt32] = [5]
    if let faceVertexCountsTimeSamplesFieldIndex {
        faceVertexCountsFieldIndexes.append(faceVertexCountsTimeSamplesFieldIndex)
    }
    var faceVertexIndicesFieldIndexes: [UInt32] = [6]
    if let faceVertexIndicesTimeSamplesFieldIndex {
        faceVertexIndicesFieldIndexes.append(faceVertexIndicesTimeSamplesFieldIndex)
    }
    let faceVertexCountsFieldSetIndex = appendFieldSet(faceVertexCountsFieldIndexes)
    let faceVertexIndicesFieldSetIndex = appendFieldSet(faceVertexIndicesFieldIndexes)
    let pointsFieldSetIndex = appendFieldSet([7])
    let subdivisionSchemeFieldSetIndex = appendFieldSet([8])

    var specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: rootFieldSetIndex, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: meshFieldSetIndex, specType: .prim),
        USDCCrateSpec(pathIndex: 2, fieldSetIndex: faceVertexCountsFieldSetIndex, specType: .attribute),
        USDCCrateSpec(pathIndex: 3, fieldSetIndex: faceVertexIndicesFieldSetIndex, specType: .attribute),
        USDCCrateSpec(pathIndex: 4, fieldSetIndex: pointsFieldSetIndex, specType: .attribute),
        USDCCrateSpec(pathIndex: 5, fieldSetIndex: subdivisionSchemeFieldSetIndex, specType: .attribute),
    ]
    var pathCount: Int
    var pathIndexes: [UInt32]
    var elementTokenIndexes: [Int32]
    var jumps: [Int32]
    if let xformFieldIndex, let xformOpOrderFieldIndex {
        var xformFieldIndexes = [xformFieldIndex]
        if let xformTimeSamplesFieldIndex {
            xformFieldIndexes.append(xformTimeSamplesFieldIndex)
        }
        specs.append(USDCCrateSpec(pathIndex: 6, fieldSetIndex: appendFieldSet(xformFieldIndexes), specType: .attribute))
        specs.append(USDCCrateSpec(pathIndex: 7, fieldSetIndex: appendFieldSet([xformOpOrderFieldIndex]), specType: .attribute))
        pathCount = 8
        pathIndexes = [0, 1, 2, 3, 4, 5, 6, 7]
        elementTokenIndexes = [0, 1, -8, -9, -10, -11, -14, -15]
        jumps = [-1, -1, 0, 0, 0, 0, 0, -2]
    } else {
        pathCount = 6
        pathIndexes = [0, 1, 2, 3, 4, 5]
        elementTokenIndexes = [0, 1, -8, -9, -10, -11]
        jumps = [-1, -1, 0, 0, 0, -2]
    }
    if let extentFieldIndex {
        let extentPathIndex = UInt32(pathCount)
        let extentFieldSetIndex = appendFieldSet([extentFieldIndex])
        specs.append(USDCCrateSpec(pathIndex: extentPathIndex, fieldSetIndex: extentFieldSetIndex, specType: .attribute))
        pathIndexes.append(extentPathIndex)
        elementTokenIndexes.append(-16)
        jumps[jumps.count - 1] = 0
        jumps.append(-2)
        pathCount += 1
    }
    if let textureCoordinateTimeSamplesFieldIndex {
        let textureCoordinatePathIndex = UInt32(pathCount)
        let textureCoordinateFieldSetIndex = appendFieldSet([textureCoordinateTimeSamplesFieldIndex])
        specs.append(USDCCrateSpec(
            pathIndex: textureCoordinatePathIndex,
            fieldSetIndex: textureCoordinateFieldSetIndex,
            specType: .attribute
        ))
        pathIndexes.append(textureCoordinatePathIndex)
        elementTokenIndexes.append(-18)
        jumps[jumps.count - 1] = 0
        jumps.append(-2)
        pathCount += 1
    }
    if let displayOpacityTimeSamplesFieldIndex {
        let displayOpacityPathIndex = UInt32(pathCount)
        let displayOpacityFieldSetIndex = appendFieldSet([displayOpacityTimeSamplesFieldIndex])
        specs.append(USDCCrateSpec(
            pathIndex: displayOpacityPathIndex,
            fieldSetIndex: displayOpacityFieldSetIndex,
            specType: .attribute
        ))
        pathIndexes.append(displayOpacityPathIndex)
        elementTokenIndexes.append(-19)
        jumps[jumps.count - 1] = 0
        jumps.append(-2)
        pathCount += 1
    }

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: fieldSetIndexes)),
        ("PATHS", makeUSDCCompressedPathsSection(
            pathCount: pathCount,
            pathIndexes: pathIndexes,
            elementTokenIndexes: elementTokenIndexes,
            jumps: jumps
        )),
        ("SPECS", makeUSDCSpecsSection(version: version, specs: specs)),
    ])
}

private func appendUSDCIntArray(_ values: [Int32], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    for value in values {
        data.appendLittleEndian(value)
    }
    return offset
}

private func appendUSDCTopologyTimeSamplesField(
    named name: String,
    blockedTopologyTimeSampleField: String?,
    sampledTopologyTimeSampleField: String?,
    sampledTopologyTimeSampleValues: [Int32],
    fallbackValueRep: USDCCrateValueRep,
    valueData: inout Data,
    fields: inout [USDCCrateField]
) -> UInt32? {
    let sampleValueRep: USDCCrateValueRep
    if blockedTopologyTimeSampleField == name {
        sampleValueRep = USDCCrateValueRep(type: .valueBlock, isInlined: false, isArray: false, payload: 0)
    } else if sampledTopologyTimeSampleField == name {
        let sampledOffset = appendUSDCIntArray(sampledTopologyTimeSampleValues, to: &valueData)
        sampleValueRep = USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: sampledOffset)
    } else {
        return nil
    }
    let timeSamplesOffset = appendUSDCTimeSamples(
        times: [1, 2],
        valueReps: [
            sampleValueRep,
            fallbackValueRep,
        ],
        to: &valueData
    )
    let fieldIndex = UInt32(fields.count)
    fields.append(USDCCrateField(
        tokenIndex: 17,
        valueRep: USDCCrateValueRep(
            type: .timeSamples,
            isInlined: false,
            isArray: false,
            payload: timeSamplesOffset
        )
    ))
    return fieldIndex
}

private func appendUSDCInt64Scalar(_ value: Int64, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(value)
    return offset
}

private func appendUSDCUInt64Scalar(_ value: UInt64, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(value)
    return offset
}

private func arrayValueRep(type: USDCCrateValueType, payload: UInt64, compressed: Bool) -> USDCCrateValueRep {
    var valueRep = USDCCrateValueRep(type: type, isInlined: false, isArray: true, payload: payload)
    if compressed {
        valueRep.rawValue |= USDCCrateValueRep.isCompressedBit
    }
    return valueRep
}

private func appendUSDCBoolArray(_ values: [Bool], compressed: Bool = false, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    var rawValueData = Data()
    for value in values {
        rawValueData.append(value ? UInt8(1) : UInt8(0))
    }
    appendUSDCArrayPayload(rawValueData, compressed: compressed, to: &data)
    return offset
}

private func appendUSDCUInt8Array(_ values: [UInt8], compressed: Bool = false, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    appendUSDCArrayPayload(Data(values), compressed: compressed, to: &data)
    return offset
}

private func appendUSDCUInt32Array(_ values: [UInt32], compressed: Bool = false, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    if compressed {
        let compressedData = compressedUInt32Payload(values)
        data.appendLittleEndian(UInt64(compressedData.count))
        data.append(compressedData)
        return offset
    }
    for value in values {
        data.appendLittleEndian(value)
    }
    return offset
}

private func appendUSDCInt64Array(_ values: [Int64], compressed: Bool = false, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    var rawValueData = Data()
    for value in values {
        rawValueData.appendLittleEndian(value)
    }
    appendUSDCArrayPayload(rawValueData, compressed: compressed, to: &data)
    return offset
}

private func appendUSDCUInt64Array(_ values: [UInt64], compressed: Bool = false, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    var rawValueData = Data()
    for value in values {
        rawValueData.appendLittleEndian(value)
    }
    appendUSDCArrayPayload(rawValueData, compressed: compressed, to: &data)
    return offset
}

private func appendUSDCVec2fScalar(_ point: USDPoint2D, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndianFloat32(Float32(point.x))
    data.appendLittleEndianFloat32(Float32(point.y))
    return offset
}

private func appendUSDCVec2dScalar(_ point: USDPoint2D, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(point.x.bitPattern)
    data.appendLittleEndian(point.y.bitPattern)
    return offset
}

private func appendUSDCVec2fArray(_ points: [USDPoint2D], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(points.count))
    for point in points {
        data.appendLittleEndianFloat32(Float32(point.x))
        data.appendLittleEndianFloat32(Float32(point.y))
    }
    return offset
}

private func appendUSDCVec3fArray(_ points: [USDPoint3D], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(points.count))
    for point in points {
        data.appendLittleEndianFloat32(Float32(point.x))
        data.appendLittleEndianFloat32(Float32(point.y))
        data.appendLittleEndianFloat32(Float32(point.z))
    }
    return offset
}

private func appendUSDCCompressedVec3fArray(_ points: [USDPoint3D], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(points.count))
    var rawValueData = Data()
    for point in points {
        rawValueData.appendLittleEndianFloat32(Float32(point.x))
        rawValueData.appendLittleEndianFloat32(Float32(point.y))
        rawValueData.appendLittleEndianFloat32(Float32(point.z))
    }
    let compressed = testFastCompression(rawValueData)
    data.appendLittleEndian(UInt64(compressed.count))
    data.append(compressed)
    return offset
}

private func appendUSDCVec3dScalar(_ vector: USDPoint3D, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(vector.x.bitPattern)
    data.appendLittleEndian(vector.y.bitPattern)
    data.appendLittleEndian(vector.z.bitPattern)
    return offset
}

private func appendUSDCMatrix4dScalar(_ values: [Double], to data: inout Data) -> UInt64 {
    precondition(values.count == 16)
    let offset = alignUSDCValueData(&data)
    for value in values {
        data.appendLittleEndian(value.bitPattern)
    }
    return offset
}

private func appendUSDCDoubleArray(_ values: [Double], compressed: Bool = false, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    var rawValueData = Data()
    for value in values {
        rawValueData.appendLittleEndian(value.bitPattern)
    }
    appendUSDCArrayPayload(rawValueData, compressed: compressed, to: &data)
    return offset
}

private func appendUSDCTimeSamples(
    times: [Double],
    valueReps: [USDCCrateValueRep],
    to data: inout Data
) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    var timesPayload = Data()
    timesPayload.appendLittleEndian(UInt64(times.count))
    for time in times {
        timesPayload.appendLittleEndian(time.bitPattern)
    }
    let timesPayloadOffset = UInt64(USDCCrateFile.bootstrapByteCount + data.count + MemoryLayout<Int64>.size)
    data.appendLittleEndian(Int64(MemoryLayout<Int64>.size + timesPayload.count))
    data.append(timesPayload)
    data.appendLittleEndian(USDCCrateValueRep(
        type: .doubleVector,
        isInlined: false,
        isArray: false,
        payload: timesPayloadOffset
    ).rawValue)
    data.appendLittleEndian(Int64(MemoryLayout<Int64>.size))
    data.appendLittleEndian(UInt64(valueReps.count))
    for valueRep in valueReps {
        data.appendLittleEndian(valueRep.rawValue)
    }
    return offset
}

private func appendUSDCArrayPayload(_ rawValueData: Data, compressed: Bool, to data: inout Data) {
    if compressed {
        let compressedData = testFastCompression(rawValueData)
        data.appendLittleEndian(UInt64(compressedData.count))
        data.append(compressedData)
    } else {
        data.append(rawValueData)
    }
}

private func appendUSDCTokenArray(_ tokenIndexes: [UInt32], compressed: Bool, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(tokenIndexes.count))
    var rawValueData = Data()
    for tokenIndex in tokenIndexes {
        rawValueData.appendLittleEndian(tokenIndex)
    }
    if compressed {
        let compressedData = testFastCompression(rawValueData)
        data.appendLittleEndian(UInt64(compressedData.count))
        data.append(compressedData)
    } else {
        data.append(rawValueData)
    }
    return offset
}

private func appendUSDCTokenVector(_ tokenIndexes: [UInt32], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(tokenIndexes.count))
    for tokenIndex in tokenIndexes {
        data.appendLittleEndian(tokenIndex)
    }
    return offset
}

private func appendUSDCStringIndex(_ stringIndex: UInt32, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(stringIndex)
    return offset
}

private func appendUSDCDoubleScalar(_ value: Double, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(value.bitPattern)
    return offset
}

private func appendUSDCDoubleVector(_ values: [Double], to data: inout Data) -> UInt64 {
    appendUSDCDoubleArray(values, to: &data)
}

private func appendUSDCStringVector(_ stringIndexes: [UInt32], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(stringIndexes.count))
    for stringIndex in stringIndexes {
        data.appendLittleEndian(stringIndex)
    }
    return offset
}

private func appendUSDCLayerOffsetVector(_ values: [SdfLayerOffset], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(values.count))
    for value in values {
        data.appendLittleEndian(value.offset.bitPattern)
        data.appendLittleEndian(value.scale.bitPattern)
    }
    return offset
}

private func appendUSDCVariantSelectionMap(_ entries: [USDCEncodedStringMapEntry], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(entries.count))
    for entry in entries {
        data.appendLittleEndian(entry.keyStringIndex)
        data.appendLittleEndian(entry.valueStringIndex)
    }
    return offset
}

private func appendUSDCPathVector(_ pathIndexes: [UInt32], to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    data.appendLittleEndian(UInt64(pathIndexes.count))
    for pathIndex in pathIndexes {
        data.appendLittleEndian(pathIndex)
    }
    return offset
}

private func appendUSDCIndexedListOperation(
    isExplicit: Bool = false,
    explicitItems: [UInt32] = [],
    addedItems: [UInt32] = [],
    prependedItems: [UInt32] = [],
    appendedItems: [UInt32] = [],
    deletedItems: [UInt32] = [],
    orderedItems: [UInt32] = [],
    to data: inout Data
) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    var header: UInt8 = isExplicit ? 1 << 0 : 0
    if !explicitItems.isEmpty {
        header |= 1 << 1
    }
    if !addedItems.isEmpty {
        header |= 1 << 2
    }
    if !deletedItems.isEmpty {
        header |= 1 << 3
    }
    if !orderedItems.isEmpty {
        header |= 1 << 4
    }
    if !prependedItems.isEmpty {
        header |= 1 << 5
    }
    if !appendedItems.isEmpty {
        header |= 1 << 6
    }
    data.append(header)
    appendUSDCListOperationItems(explicitItems, to: &data)
    appendUSDCListOperationItems(addedItems, to: &data)
    appendUSDCListOperationItems(prependedItems, to: &data)
    appendUSDCListOperationItems(appendedItems, to: &data)
    appendUSDCListOperationItems(deletedItems, to: &data)
    appendUSDCListOperationItems(orderedItems, to: &data)
    return offset
}

private func appendUSDCListOperationItems(_ items: [UInt32], to data: inout Data) {
    guard !items.isEmpty else {
        return
    }
    data.appendLittleEndian(UInt64(items.count))
    for item in items {
        data.appendLittleEndian(item)
    }
}

private struct USDCEncodedReference {
    var assetPathStringIndex: UInt32
    var primPathIndex: UInt32
    var layerOffset: SdfLayerOffset
    var customData: [USDCEncodedDictionaryEntry] = []
}

private struct USDCEncodedPayload {
    var assetPathStringIndex: UInt32
    var primPathIndex: UInt32
    var layerOffset: SdfLayerOffset
}

struct USDCEncodedDictionaryEntry {
    var keyStringIndex: UInt32
    var valueRep: USDCCrateValueRep
    var nestedPayload: Data = Data()
    var usesNestedPayloadOffset = false
}

private struct USDCEncodedStringMapEntry {
    var keyStringIndex: UInt32
    var valueStringIndex: UInt32
}

private func appendUSDCReferenceListOperation(
    explicitItems: [USDCEncodedReference] = [],
    addedItems: [USDCEncodedReference] = [],
    prependedItems: [USDCEncodedReference] = [],
    appendedItems: [USDCEncodedReference] = [],
    deletedItems: [USDCEncodedReference] = [],
    orderedItems: [USDCEncodedReference] = [],
    to data: inout Data
) -> UInt64 {
    appendUSDCListOperation(
        explicitItems: explicitItems,
        addedItems: addedItems,
        prependedItems: prependedItems,
        appendedItems: appendedItems,
        deletedItems: deletedItems,
        orderedItems: orderedItems,
        to: &data
    ) { reference, output in
        output.appendLittleEndian(reference.assetPathStringIndex)
        output.appendLittleEndian(reference.primPathIndex)
        output.appendLittleEndian(reference.layerOffset.offset.bitPattern)
        output.appendLittleEndian(reference.layerOffset.scale.bitPattern)
        appendUSDCDictionary(reference.customData, to: &output)
    }
}

func appendUSDCDictionary(_ entries: [USDCEncodedDictionaryEntry], to data: inout Data) {
    data.appendLittleEndian(UInt64(entries.count))
    for entry in entries {
        data.appendLittleEndian(entry.keyStringIndex)
        let nestedPayloadOffset = UInt64(USDCCrateFile.bootstrapByteCount + data.count + MemoryLayout<Int64>.size)
        var valueRep = entry.valueRep
        if entry.usesNestedPayloadOffset {
            valueRep.rawValue = (valueRep.rawValue & ~USDCCrateValueRep.payloadMask) | (nestedPayloadOffset & USDCCrateValueRep.payloadMask)
        }
        data.appendLittleEndian(Int64(MemoryLayout<Int64>.size + entry.nestedPayload.count))
        data.append(entry.nestedPayload)
        data.appendLittleEndian(valueRep.rawValue)
    }
}

private func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
    var data = Data()
    data.appendLittleEndian(value)
    return data
}

private func appendUSDCPayloadListOperation(
    explicitItems: [USDCEncodedPayload] = [],
    addedItems: [USDCEncodedPayload] = [],
    prependedItems: [USDCEncodedPayload] = [],
    appendedItems: [USDCEncodedPayload] = [],
    deletedItems: [USDCEncodedPayload] = [],
    orderedItems: [USDCEncodedPayload] = [],
    to data: inout Data
) -> UInt64 {
    appendUSDCListOperation(
        explicitItems: explicitItems,
        addedItems: addedItems,
        prependedItems: prependedItems,
        appendedItems: appendedItems,
        deletedItems: deletedItems,
        orderedItems: orderedItems,
        to: &data
    ) { payload, output in
        appendUSDCPayloadBytes(payload, to: &output)
    }
}

private func appendUSDCListOperation<Item>(
    isExplicit: Bool = false,
    explicitItems: [Item] = [],
    addedItems: [Item] = [],
    prependedItems: [Item] = [],
    appendedItems: [Item] = [],
    deletedItems: [Item] = [],
    orderedItems: [Item] = [],
    to data: inout Data,
    appendItem: (Item, inout Data) -> Void
) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    var header: UInt8 = isExplicit ? 1 << 0 : 0
    if !explicitItems.isEmpty {
        header |= 1 << 1
    }
    if !addedItems.isEmpty {
        header |= 1 << 2
    }
    if !deletedItems.isEmpty {
        header |= 1 << 3
    }
    if !orderedItems.isEmpty {
        header |= 1 << 4
    }
    if !prependedItems.isEmpty {
        header |= 1 << 5
    }
    if !appendedItems.isEmpty {
        header |= 1 << 6
    }
    data.append(header)
    appendUSDCListOperationItems(explicitItems, to: &data, appendItem: appendItem)
    appendUSDCListOperationItems(addedItems, to: &data, appendItem: appendItem)
    appendUSDCListOperationItems(prependedItems, to: &data, appendItem: appendItem)
    appendUSDCListOperationItems(appendedItems, to: &data, appendItem: appendItem)
    appendUSDCListOperationItems(deletedItems, to: &data, appendItem: appendItem)
    appendUSDCListOperationItems(orderedItems, to: &data, appendItem: appendItem)
    return offset
}

private func appendUSDCListOperationItems<Item>(
    _ items: [Item],
    to data: inout Data,
    appendItem: (Item, inout Data) -> Void
) {
    guard !items.isEmpty else {
        return
    }
    data.appendLittleEndian(UInt64(items.count))
    for item in items {
        appendItem(item, &data)
    }
}

@discardableResult
private func appendUSDCPayload(_ payload: USDCEncodedPayload, to data: inout Data) -> UInt64 {
    let offset = alignUSDCValueData(&data)
    appendUSDCPayloadBytes(payload, to: &data)
    return offset
}

private func appendUSDCPayloadBytes(_ payload: USDCEncodedPayload, to data: inout Data) {
    data.appendLittleEndian(payload.assetPathStringIndex)
    data.appendLittleEndian(payload.primPathIndex)
    data.appendLittleEndian(payload.layerOffset.offset.bitPattern)
    data.appendLittleEndian(payload.layerOffset.scale.bitPattern)
}

private func alignUSDCValueData(_ data: inout Data) -> UInt64 {
    while (USDCCrateFile.bootstrapByteCount + data.count) % MemoryLayout<UInt64>.size != 0 {
        data.append(0)
    }
    return UInt64(USDCCrateFile.bootstrapByteCount + data.count)
}

private func openUSDFixture(_ relativePath: String) throws -> Data {
    try fixtureData(root: "OpenUSD", relativePath: relativePath)
}

func generatedFixture(_ relativePath: String) throws -> Data {
    try fixtureData(root: "Generated", relativePath: relativePath)
}

private func usdImportFailureMessage(_ body: () throws -> Void) throws -> String {
    do {
        try body()
    } catch let error as USDError {
        return error.testMessage
    } catch {
        Issue.record("Expected USDError, got \(error).")
        return ""
    }
    Issue.record("Expected USDError.")
    return ""
}

private func makeOpenUSDUSDSiblingPackage(root: String) throws -> Data {
    try makeUSDZFixture(entries: [
        (root, openUSDFixture("testUsdUsdzFileFormat/\(root)")),
        ("single_usd.usdz", openUSDFixture("testUsdUsdzFileFormat/single_usd.usdz")),
        ("single_usda.usdz", openUSDFixture("testUsdUsdzFileFormat/single_usda.usdz")),
        ("single_usdc.usdz", openUSDFixture("testUsdUsdzFileFormat/single_usdc.usdz")),
    ], alignPayloads: true)
}

private func defaultFieldValueRep(in crate: USDCCrateFile, atPath path: String) throws -> USDCCrateValueRep {
    let paths = try crate.readPaths()
    let specs = try crate.readSpecs()
    let fieldSetIndexes = try crate.readFieldSetIndexes()
    let fields = try crate.readFields()
    let tokens = try crate.readTokens()
    guard let pathIndex = paths.firstIndex(of: path) else {
        throw USDError.invalidData("USDC fixture is missing path \(path).")
    }
    guard let spec = specs.first(where: { Int($0.pathIndex) == pathIndex }) else {
        throw USDError.invalidData("USDC fixture is missing spec for path \(path).")
    }
    var cursor = Int(spec.fieldSetIndex)
    while cursor < fieldSetIndexes.count {
        let fieldIndex = fieldSetIndexes[cursor]
        cursor += 1
        if fieldIndex == UInt32.max {
            break
        }
        guard fieldIndex < UInt32(fields.count) else {
            throw USDError.invalidData("USDC fixture field set references an out-of-range field.")
        }
        let field = fields[Int(fieldIndex)]
        guard field.tokenIndex < UInt32(tokens.count) else {
            throw USDError.invalidData("USDC fixture field references an out-of-range token.")
        }
        if tokens[Int(field.tokenIndex)] == "default" {
            return field.valueRep
        }
    }
    throw USDError.invalidData("USDC fixture is missing a default field for path \(path).")
}

private extension USDError {
    var testMessage: String {
        switch self {
        case .invalidData(let message),
             .missingRequiredField(let message),
             .unsupportedFeature(let message),
             .notImplemented(let message):
            return message
        }
    }
}

private func fixtureData(root: String, relativePath: String) throws -> Data {
    #if SWIFT_PACKAGE
    if let resourceURL = Bundle.module.resourceURL {
        let fixtureURL = resourceURL
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(root)
            .appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: fixtureURL.path) {
            return try Data(contentsOf: fixtureURL)
        }
    }
    #endif
    let testFileURL = URL(fileURLWithPath: #filePath)
    let fixturesURL = testFileURL
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(root)
    return try Data(contentsOf: fixturesURL.appendingPathComponent(relativePath))
}

func makeUSDCTokenSection(version: USDCCrateVersion, tokenData: Data) -> Data {
    let tokens = tokenData.filter { $0 == 0 }.count
    var data = Data()
    data.appendLittleEndian(UInt64(tokens))
    if version < USDCCrateVersion(major: 0, minor: 4, patch: 0) {
        data.appendLittleEndian(UInt64(tokenData.count))
        data.append(tokenData)
    } else {
        let compressed = testFastCompression(tokenData)
        data.appendLittleEndian(UInt64(tokenData.count))
        data.appendLittleEndian(UInt64(compressed.count))
        data.append(compressed)
    }
    return data
}

func makeUSDCStringsSection(_ tokenIndexes: [UInt32]) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt64(tokenIndexes.count))
    for tokenIndex in tokenIndexes {
        data.appendLittleEndian(tokenIndex)
    }
    return data
}

func makeUSDCFieldsSection(version: USDCCrateVersion, fields: [USDCCrateField]) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt64(fields.count))
    if version < USDCCrateVersion(major: 0, minor: 4, patch: 0) {
        for field in fields {
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(field.tokenIndex)
            data.appendLittleEndian(field.valueRep.rawValue)
        }
    } else {
        data.append(compressedUInt32List(fields.map(\.tokenIndex)))
        var valueRepBytes = Data()
        for field in fields {
            valueRepBytes.appendLittleEndian(field.valueRep.rawValue)
        }
        let compressedValueReps = testFastCompression(valueRepBytes)
        data.appendLittleEndian(UInt64(compressedValueReps.count))
        data.append(compressedValueReps)
    }
    return data
}

func makeUSDCFieldSetsSection(version: USDCCrateVersion, indexes: [UInt32]) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt64(indexes.count))
    if version < USDCCrateVersion(major: 0, minor: 4, patch: 0) {
        for index in indexes {
            data.appendLittleEndian(index)
        }
    } else {
        data.append(compressedUInt32List(indexes))
    }
    return data
}

func makeUSDCCompressedPathsSection(
    pathCount: Int,
    pathIndexes: [UInt32],
    elementTokenIndexes: [Int32],
    jumps: [Int32]
) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt64(pathCount))
    data.appendLittleEndian(UInt64(pathIndexes.count))
    data.append(compressedUInt32List(pathIndexes))
    data.append(compressedInt32List(elementTokenIndexes))
    data.append(compressedInt32List(jumps))
    return data
}

func makeUSDCSpecsSection(version: USDCCrateVersion, specs: [USDCCrateSpec]) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt64(specs.count))
    if version == USDCCrateVersion(major: 0, minor: 0, patch: 1) {
        for spec in specs {
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(spec.pathIndex)
            data.appendLittleEndian(spec.fieldSetIndex)
            data.appendLittleEndian(spec.specType.rawValue)
        }
    } else if version < USDCCrateVersion(major: 0, minor: 4, patch: 0) {
        for spec in specs {
            data.appendLittleEndian(spec.pathIndex)
            data.appendLittleEndian(spec.fieldSetIndex)
            data.appendLittleEndian(spec.specType.rawValue)
        }
    } else {
        data.append(compressedUInt32List(specs.map(\.pathIndex)))
        data.append(compressedUInt32List(specs.map(\.fieldSetIndex)))
        data.append(compressedUInt32List(specs.map(\.specType.rawValue)))
    }
    return data
}

func nullSeparatedTokenData(_ tokens: [String]) -> Data {
    var data = Data()
    for token in tokens {
        data.append(contentsOf: token.utf8)
        data.append(0)
    }
    return data
}

private func compressedInt32List(_ values: [Int32]) -> Data {
    compressedUInt32List(values.map { UInt32(bitPattern: $0) })
}

private func compressedUInt32List(_ values: [UInt32]) -> Data {
    let payload = compressedUInt32Payload(values)
    var data = Data()
    data.appendLittleEndian(UInt64(payload.count))
    data.append(payload)
    return data
}

private func compressedUInt32Payload(_ values: [UInt32]) -> Data {
    testFastCompression(integerEncodedData(values))
}

private func integerEncodedData(_ values: [UInt32]) -> Data {
    guard !values.isEmpty else {
        return Data()
    }
    let deltas = integerDeltas(values)
    let commonValue = mostCommonIntegerDelta(deltas)
    var output = Data()
    output.appendLittleEndian(commonValue)
    var codes = [UInt8](repeating: 0, count: (values.count * 2 + 7) / 8)
    var variableIntegers = Data()
    for (index, delta) in deltas.enumerated() {
        let code: UInt8
        if delta == commonValue {
            code = 0
        } else if delta >= Int32(Int8.min), delta <= Int32(Int8.max) {
            code = 1
            variableIntegers.append(UInt8(bitPattern: Int8(truncatingIfNeeded: delta)))
        } else if delta >= Int32(Int16.min), delta <= Int32(Int16.max) {
            code = 2
            variableIntegers.appendLittleEndian(Int16(truncatingIfNeeded: delta))
        } else {
            code = 3
            variableIntegers.appendLittleEndian(delta)
        }
        codes[index / 4] |= code << UInt8((index % 4) * 2)
    }
    output.append(contentsOf: codes)
    output.append(variableIntegers)
    return output
}

private func integerDeltas(_ values: [UInt32]) -> [Int32] {
    var previous = Int32(0)
    return values.map { value in
        let signedValue = Int32(bitPattern: value)
        let delta = signedValue &- previous
        previous = signedValue
        return delta
    }
}

private func mostCommonIntegerDelta(_ deltas: [Int32]) -> Int32 {
    var counts: [Int32: Int] = [:]
    for delta in deltas {
        counts[delta, default: 0] += 1
    }
    return counts.max { lhs, rhs in
        if lhs.value != rhs.value {
            return lhs.value < rhs.value
        }
        return lhs.key < rhs.key
    }?.key ?? 0
}

private func testFastCompression(_ data: Data) -> Data {
    var compressed = Data([0])
    compressed.append(testLZ4LiteralBlock(Array(data)))
    return compressed
}

private func testLZ4LiteralBlock(_ bytes: [UInt8]) -> Data {
    var output = Data()
    var literalCount = bytes.count
    let tokenHighNibble = min(literalCount, 15)
    output.append(UInt8(tokenHighNibble << 4))
    if literalCount >= 15 {
        literalCount -= 15
        while literalCount >= 255 {
            output.append(255)
            literalCount -= 255
        }
        output.append(UInt8(literalCount))
    }
    output.append(contentsOf: bytes)
    return output
}

private func referenceLayer(name: String, rootPath: String, uniqueChildName: String) -> USDALayer {
    USDALayer(defaultPrim: String(rootPath.dropFirst()), specs: [
        USDLayerSpec(path: "/", specType: .pseudoRoot),
        USDLayerSpec(path: rootPath, specType: .prim, specifier: .def, typeName: "Xform"),
        USDLayerSpec(path: "\(rootPath)/\(uniqueChildName)", specType: .prim, specifier: .def, typeName: "Mesh"),
        USDLayerSpec(
            path: "\(rootPath)/Shared",
            specType: .prim,
            specifier: .def,
            typeName: "Mesh",
            fields: ["displayName": .authored("\"\(name)\"")]
        ),
    ])
}

private func makeUSDZFixture(entries: [(String, Data)], alignPayloads: Bool) -> Data {
    var data = Data()
    var centralRecords: [(path: String, localHeaderOffset: Int, crc: UInt32, size: Int)] = []

    for entry in entries {
        let localHeaderOffset = data.count
        let nameData = Data(entry.0.utf8)
        let crc = testCRC32(entry.1)
        let payloadStartWithoutPadding = localHeaderOffset + 30 + nameData.count
        let extraLength = alignPayloads ? ((64 - (payloadStartWithoutPadding % 64)) % 64) : 0

        data.appendLittleEndian(UInt32(0x04034b50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(crc)
        data.appendLittleEndian(UInt32(entry.1.count))
        data.appendLittleEndian(UInt32(entry.1.count))
        data.appendLittleEndian(UInt16(nameData.count))
        data.appendLittleEndian(UInt16(extraLength))
        data.append(nameData)
        data.append(Data(repeating: 0, count: extraLength))
        data.append(entry.1)
        centralRecords.append((entry.0, localHeaderOffset, crc, entry.1.count))
    }

    let centralDirectoryOffset = data.count
    var centralDirectory = Data()
    for record in centralRecords {
        let nameData = Data(record.path.utf8)
        centralDirectory.appendLittleEndian(UInt32(0x02014b50))
        centralDirectory.appendLittleEndian(UInt16(20))
        centralDirectory.appendLittleEndian(UInt16(20))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(record.crc)
        centralDirectory.appendLittleEndian(UInt32(record.size))
        centralDirectory.appendLittleEndian(UInt32(record.size))
        centralDirectory.appendLittleEndian(UInt16(nameData.count))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt32(0))
        centralDirectory.appendLittleEndian(UInt32(record.localHeaderOffset))
        centralDirectory.append(nameData)
    }
    data.append(centralDirectory)
    data.appendLittleEndian(UInt32(0x06054b50))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(centralRecords.count))
    data.appendLittleEndian(UInt16(centralRecords.count))
    data.appendLittleEndian(UInt32(centralDirectory.count))
    data.appendLittleEndian(UInt32(centralDirectoryOffset))
    data.appendLittleEndian(UInt16(0))
    return data
}

private func testCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        let index = Int((crc ^ UInt32(byte)) & 0xff)
        crc = (crc >> 8) ^ testCRC32Table[index]
    }
    return crc ^ 0xffff_ffff
}

private let testCRC32Table: [UInt32] = {
    (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}()

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndianFloat32(_ value: Float32) {
        appendLittleEndian(value.bitPattern)
    }

    mutating func appendFixedASCII(_ string: String, byteCount: Int) {
        let bytes = Array(string.utf8)
        append(contentsOf: bytes.prefix(byteCount))
        if bytes.count < byteCount {
            append(Data(repeating: 0, count: byteCount - bytes.count))
        }
    }
}
