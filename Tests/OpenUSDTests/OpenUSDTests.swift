import Foundation
import Testing
import OpenUSD
import OpenUSDC
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

        #expect(throws: USDImportError.self) {
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
    func generatedUSDCBlockedRequiredDefaultFixtureReportsMissingField() throws {
        let fixture = try generatedFixture("blocked_required_default_mesh.usdc")

        do {
            _ = try USDCReader().read(from: fixture)
            Issue.record("Expected blocked points to be reported as a missing required field.")
        } catch USDImportError.missingRequiredField(let field) {
            #expect(field == "points")
        } catch {
            Issue.record("Expected missingRequiredField(\"points\"), got \(error).")
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
    func openUSDSDFParsingNamespacedPropertySpecsReadLayer() throws {
        let data = try openUSDFixture("testSdfParsing.testenv/185_namespaced_properties.usda")

        let layer = try USDAReader().readLayer(from: data)

        #expect(layer.prims.map(\.path).sorted() == ["/Prim", "/Prim/Child"])
        let prim = try #require(layer.spec(at: "/Prim"))
        #expect(prim.fieldNames.contains("properties"))
        let child = try #require(layer.spec(at: "/Prim/Child"))
        #expect(!child.fieldNames.contains("properties"))
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
        } catch USDImportError.invalidData(let message) {
            #expect(message.contains("valid identifier"))
            #expect(message.contains("㤼01৪∫"))
        } catch {
            Issue.record("Expected USDImportError.invalidData, got \(error).")
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
            layerOffset: USDLayerOffset(offset: 11, scale: 22)
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
            layerOffset: USDLayerOffset(offset: 11, scale: 22)
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "@/test/layer3.usda@",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: "/Prim"
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "@/test/layer4.usda@",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: nil
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "@/test/layer3.usda@",
            sitePrimPath: "/TestMixed3",
            targetPrimPath: "/Prim"
        )))
        #expect(references.contains(USDCompositionArc(
            assetPath: "@/test/layer4.usda@",
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
                layerOffset: USDLayerOffset(offset: 0.1, scale: 0.2)
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
                layerOffset: USDLayerOffset(offset: 11, scale: 22)
            ),
            USDCompositionArc(
                assetPath: "///test1/layer1.usda",
                sitePrimPath: "/TestSubrootPrim3",
                targetPrimPath: "/Prim2/Child",
                layerOffset: USDLayerOffset(offset: 0.1, scale: 0.2)
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
            layerOffset: USDLayerOffset(offset: 11, scale: 22)
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
            layerOffset: USDLayerOffset(offset: 11, scale: 22)
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "@/test/layer3.usda@",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: "/Prim"
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "@/test/layer4.usda@",
            sitePrimPath: "/TestMixed2",
            targetPrimPath: nil
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "@/test/layer3.usda@",
            sitePrimPath: "/TestMixed3",
            targetPrimPath: "/Prim"
        )))
        #expect(payloads.contains(USDCompositionArc(
            assetPath: "@/test/layer4.usda@",
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
                layerOffset: USDLayerOffset(offset: 0.1, scale: 0.2)
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
                layerOffset: USDLayerOffset(offset: 11, scale: 22)
            ),
            USDCompositionArc(
                assetPath: "///test1/layer1.usda",
                sitePrimPath: "/TestSubrootPrim3",
                targetPrimPath: "/Prim2/Child",
                layerOffset: USDLayerOffset(offset: 0.1, scale: 0.2)
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
            USDLayerOffset(offset: 10, scale: 0.5),
            .identity,
        ]))
        #expect(layer.composition.sublayers == [
            USDSublayer(assetPath: "layers/base.usda", layerOffset: USDLayerOffset(offset: 10, scale: 0.5)),
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
                    layerOffset: USDLayerOffset(offset: 1.5, scale: 2),
                    customData: [
                        "displayName": .string("friendlyRef"),
                        "referencePurpose": .string("render"),
                    ]
                ),
                USDCReference(
                    assetPath: "assets/second.usda",
                    primPath: "/Scope.target"
                ),
            ]
        )))
        #expect(scope.fields["payload"] == .payloadListOperation(USDCListOperation(
            prependedItems: [
                USDCPayload(
                    assetPath: "assets/payload.usdc",
                    primPath: "/PayloadTarget",
                    layerOffset: USDLayerOffset(offset: -2, scale: 0.5)
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
                layerOffset: USDLayerOffset(offset: 1.5, scale: 2)
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
                layerOffset: USDLayerOffset(offset: -2, scale: 0.5)
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
        let offset = USDLayerOffset(offset: 10, scale: 2)

        #expect(offset.stageTime(forLayerTime: 12) == 34)
        #expect(try offset.layerTime(forStageTime: 34) == 12)
        #expect(offset.concatenating(USDLayerOffset(offset: 3, scale: 4)) == USDLayerOffset(offset: 16, scale: 8))
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
                layerOffset: USDLayerOffset(offset: 10, scale: 0.5)
            ),
        ])
        #expect(layer.composition.references == [
            USDCompositionArc(
                assetPath: "./refs/model.usda",
                sitePrimPath: "/Scene",
                targetPrimPath: "/Model",
                layerOffset: USDLayerOffset(offset: 24, scale: 2)
            ),
        ])
        #expect(layer.composition.payloads == [
            USDCompositionArc(
                assetPath: "./payloads/heavy.usdc",
                sitePrimPath: "/Scene",
                targetPrimPath: "/Payload",
                layerOffset: USDLayerOffset(offset: -3, scale: 0.25)
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

        #expect(throws: USDImportError.self) {
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

        #expect(throws: USDImportError.self) {
            _ = try USDZReader().read(from: data)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func usdcSceneReaderRequiresStructuralSections() throws {
        let data = makeUSDCFixture(sections: [
            ("TOKENS", Data([0x01])),
        ])

        #expect(throws: USDImportError.self) {
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

        #expect(throws: USDImportError.self) {
            _ = try USDZArchive(data: package)
        }
    }
}

private func makeUSDCFixture(
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
        USDLayerOffset(offset: 10, scale: 0.5),
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
            valueRep: USDCCrateValueRep(type: .permission, isInlined: true, isArray: false, payload: UInt64(USDPermission.privateAccess.rawValue))
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
    ]
    let specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 3, specType: .prim),
    ]

    return makeUSDCFixture(version: version, valueData: valueData, sections: [
        ("TOKENS", makeUSDCTokenSection(version: version, tokenData: nullSeparatedTokenData(tokens))),
        ("STRINGS", makeUSDCStringsSection([12, 13, 14, 15, 16, 17, 18, 19])),
        ("FIELDS", makeUSDCFieldsSection(version: version, fields: fields)),
        ("FIELDSETS", makeUSDCFieldSetsSection(version: version, indexes: [
            1, 2, UInt32.max,
            0, 3, 4, 5, 6, 7, 8, 9, 10, UInt32.max,
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
                layerOffset: USDLayerOffset(offset: 1.5, scale: 2),
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
        to: &valueData
    )
    let payloadListOperationOffset = appendUSDCPayloadListOperation(
        prependedItems: [
            USDCEncodedPayload(
                assetPathStringIndex: 1,
                primPathIndex: 3,
                layerOffset: USDLayerOffset(offset: -2, scale: 0.5)
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

private func makeUSDCReferenceLayerFixture(assetPath: String) -> Data {
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
                primPathIndex: 2,
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

private func makeUSDCMeshSceneFixture(
    compressedPoints: Bool = false,
    compressedXformOpOrder: Bool = false
) -> Data {
    let version = USDCCrateVersion(major: 0, minor: 8, patch: 0)
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
        "xformOp:translate",
        "xformOpOrder",
    ]
    var valueData = Data()
    let faceVertexCountsOffset = appendUSDCIntArray([3], to: &valueData)
    let faceVertexIndicesOffset = appendUSDCIntArray([0, 1, 2], to: &valueData)
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
    let translateOffset: UInt64?
    let xformOpOrderOffset: UInt64?
    if compressedXformOpOrder {
        translateOffset = appendUSDCVec3dScalar(USDPoint3D(x: 2, y: 3, z: 4), to: &valueData)
        xformOpOrderOffset = appendUSDCTokenArray([14], compressed: true, to: &valueData)
    } else {
        translateOffset = nil
        xformOpOrderOffset = nil
    }

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
            valueRep: USDCCrateValueRep(type: .specifier, isInlined: true, isArray: false, payload: 0)
        ),
        USDCCrateField(
            tokenIndex: 6,
            valueRep: USDCCrateValueRep(type: .token, isInlined: true, isArray: false, payload: 7)
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexCountsOffset)
        ),
        USDCCrateField(
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(type: .int, isInlined: false, isArray: true, payload: faceVertexIndicesOffset)
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
    if let translateOffset, let xformOpOrderOffset {
        fields.append(USDCCrateField(
            tokenIndex: 12,
            valueRep: USDCCrateValueRep(type: .vec3d, isInlined: false, isArray: false, payload: translateOffset)
        ))
        var xformOpOrderValueRep = USDCCrateValueRep(type: .token, isInlined: false, isArray: true, payload: xformOpOrderOffset)
        xformOpOrderValueRep.rawValue |= USDCCrateValueRep.isCompressedBit
        fields.append(USDCCrateField(
            tokenIndex: 12,
            valueRep: xformOpOrderValueRep
        ))
    }
    var fieldSetIndexes: [UInt32] = [
        0, 1, 2, UInt32.max,
        3, 4, UInt32.max,
        5, UInt32.max,
        6, UInt32.max,
        7, UInt32.max,
        8, UInt32.max,
    ]
    var specs = [
        USDCCrateSpec(pathIndex: 0, fieldSetIndex: 0, specType: .pseudoRoot),
        USDCCrateSpec(pathIndex: 1, fieldSetIndex: 4, specType: .prim),
        USDCCrateSpec(pathIndex: 2, fieldSetIndex: 7, specType: .attribute),
        USDCCrateSpec(pathIndex: 3, fieldSetIndex: 9, specType: .attribute),
        USDCCrateSpec(pathIndex: 4, fieldSetIndex: 11, specType: .attribute),
        USDCCrateSpec(pathIndex: 5, fieldSetIndex: 13, specType: .attribute),
    ]
    let pathCount: Int
    let pathIndexes: [UInt32]
    let elementTokenIndexes: [Int32]
    let jumps: [Int32]
    if compressedXformOpOrder {
        fieldSetIndexes.append(contentsOf: [9, UInt32.max, 10, UInt32.max])
        specs.append(USDCCrateSpec(pathIndex: 6, fieldSetIndex: 15, specType: .attribute))
        specs.append(USDCCrateSpec(pathIndex: 7, fieldSetIndex: 17, specType: .attribute))
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

private func appendUSDCLayerOffsetVector(_ values: [USDLayerOffset], to data: inout Data) -> UInt64 {
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
    var layerOffset: USDLayerOffset
    var customData: [USDCEncodedDictionaryEntry] = []
}

private struct USDCEncodedPayload {
    var assetPathStringIndex: UInt32
    var primPathIndex: UInt32
    var layerOffset: USDLayerOffset
}

private struct USDCEncodedDictionaryEntry {
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

private func appendUSDCDictionary(_ entries: [USDCEncodedDictionaryEntry], to data: inout Data) {
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

private func generatedFixture(_ relativePath: String) throws -> Data {
    try fixtureData(root: "Generated", relativePath: relativePath)
}

private func usdImportFailureMessage(_ body: () throws -> Void) throws -> String {
    do {
        try body()
    } catch let error as USDImportError {
        return error.testMessage
    } catch {
        Issue.record("Expected USDImportError, got \(error).")
        return ""
    }
    Issue.record("Expected USDImportError.")
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
        throw USDImportError.invalidData("USDC fixture is missing path \(path).")
    }
    guard let spec = specs.first(where: { Int($0.pathIndex) == pathIndex }) else {
        throw USDImportError.invalidData("USDC fixture is missing spec for path \(path).")
    }
    var cursor = Int(spec.fieldSetIndex)
    while cursor < fieldSetIndexes.count {
        let fieldIndex = fieldSetIndexes[cursor]
        cursor += 1
        if fieldIndex == UInt32.max {
            break
        }
        guard fieldIndex < UInt32(fields.count) else {
            throw USDImportError.invalidData("USDC fixture field set references an out-of-range field.")
        }
        let field = fields[Int(fieldIndex)]
        guard field.tokenIndex < UInt32(tokens.count) else {
            throw USDImportError.invalidData("USDC fixture field references an out-of-range token.")
        }
        if tokens[Int(field.tokenIndex)] == "default" {
            return field.valueRep
        }
    }
    throw USDImportError.invalidData("USDC fixture is missing a default field for path \(path).")
}

private extension USDImportError {
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

private func makeUSDCTokenSection(version: USDCCrateVersion, tokenData: Data) -> Data {
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

private func makeUSDCStringsSection(_ tokenIndexes: [UInt32]) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt64(tokenIndexes.count))
    for tokenIndex in tokenIndexes {
        data.appendLittleEndian(tokenIndex)
    }
    return data
}

private func makeUSDCFieldsSection(version: USDCCrateVersion, fields: [USDCCrateField]) -> Data {
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

private func makeUSDCFieldSetsSection(version: USDCCrateVersion, indexes: [UInt32]) -> Data {
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

private func makeUSDCCompressedPathsSection(
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

private func makeUSDCSpecsSection(version: USDCCrateVersion, specs: [USDCCrateSpec]) -> Data {
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

private func nullSeparatedTokenData(_ tokens: [String]) -> Data {
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
