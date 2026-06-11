import Foundation
import Testing
import OpenUSD

@Suite("USDATextInterop")
struct USDATextInteropTests {

    // MARK: - Quoted string escapes

    @Test(.timeLimit(.minutes(1)))
    func bareDocumentationStringDecodesEscapesAndReencodesCanonically() throws {
        let source = #"""
        #usda 1.0
        (
            "Line1\nLine2 \"quoted\" \x41\102"
        )

        def Xform "Root"
        {
        }
        """#
        let layer = try USDAReader().readLayer(from: source)
        let documentation = try #require(layer.spec(at: "/")?.fields["documentation"])
        #expect(documentation == .authored(#""Line1\nLine2 \"quoted\" AB""#))
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicatePrimMetadataFieldIsRejected() {
        let source = #"""
        #usda 1.0

        def Xform "Root" (
            hidden = true
            hidden = false
        )
        {
        }
        """#
        #expect(throws: USDError.invalidData("USDA metadata block contains duplicate field hidden.")) {
            _ = try USDAReader().readLayer(from: source)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func primMetadataFieldWithoutValueIsRejected() {
        let source = #"""
        #usda 1.0

        def Xform "Root" (
            instanceable =
        )
        {
        }
        """#
        #expect(throws: USDError.invalidData("USDA metadata field instanceable has no value.")) {
            _ = try USDAReader().readLayer(from: source)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func primMetadataStatementWithEmptyFieldNameIsRejected() {
        let source = #"""
        #usda 1.0

        def Xform "Root" (
            = true
        )
        {
        }
        """#
        #expect(
            throws: USDError.invalidData(
                "USDA metadata block contains a statement with an empty field name."
            )
        ) {
            _ = try USDAReader().readLayer(from: source)
        }
    }

    // MARK: - Triple-delimited asset paths

    @Test(.timeLimit(.minutes(1)))
    func tripleDelimitedAssetPathDecodesEscapedDelimiterRuns() throws {
        let source = #"""
        #usda 1.0

        def Xform "Root" (
            references = @@@weird@@path\@@@file.usda@@@</Target>
        )
        {
        }
        """#
        let layer = try USDAReader().readLayer(from: source)
        let references = try #require(layer.spec(at: "/Root")?.fields["references"])
        let expected = SdfListOperation(
            isExplicit: true,
            explicitItems: [
                SdfReference(
                    assetPath: "weird@@path@@@file.usda",
                    primPath: try SdfPath("/Target")
                ),
            ]
        )
        #expect(references == .referenceListOperation(expected))
    }

    @Test(.timeLimit(.minutes(1)))
    func tripleDelimitedAssetPathRoundTripsThroughWriter() throws {
        let source = #"""
        #usda 1.0

        def Xform "Root" (
            references = @@@weird@@path\@@@file.usda@@@</Target>
        )
        {
        }
        """#
        let layer = try USDAReader().readLayer(from: source)
        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)
        #expect(
            roundTripped.spec(at: "/Root")?.fields["references"]
                == layer.spec(at: "/Root")?.fields["references"]
        )
    }

    // MARK: - Document order

    @Test(.timeLimit(.minutes(1)))
    func writerPreservesPrimDocumentOrder() throws {
        let source = """
        #usda 1.0

        def Xform "Zebra"
        {
        }

        def Xform "Alpha"
        {
        }

        def Xform "Middle"
        {
        }
        """
        let layer = try USDAReader().readLayer(from: source)
        #expect(layer.prims.map(\.path) == ["/Zebra", "/Alpha", "/Middle"])

        let written = try USDAWriter().string(for: layer)
        let zebra = try #require(written.range(of: "\"Zebra\""))
        let alpha = try #require(written.range(of: "\"Alpha\""))
        let middle = try #require(written.range(of: "\"Middle\""))
        #expect(zebra.lowerBound < alpha.lowerBound)
        #expect(alpha.lowerBound < middle.lowerBound)

        let roundTripped = try USDAReader().readLayer(from: written)
        #expect(roundTripped.prims.map(\.path) == ["/Zebra", "/Alpha", "/Middle"])
    }

    @Test(.timeLimit(.minutes(1)))
    func writerPreservesDeepHierarchyDocumentOrder() throws {
        let source = """
        #usda 1.0

        def Xform "Root"
        {
            def Scope "Zebra"
            {
                def Scope "Inner"
                {
                }
            }

            def Scope "Alpha"
            {
            }
        }

        def Xform "Other"
        {
        }
        """
        let expectedPrimPaths = ["/Root", "/Root/Zebra", "/Root/Zebra/Inner", "/Root/Alpha", "/Other"]
        let layer = try USDAReader().readLayer(from: source)
        #expect(layer.prims.map(\.path) == expectedPrimPaths)

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)
        #expect(roundTripped.prims.map(\.path) == expectedPrimPaths)
    }

    @Test(.timeLimit(.minutes(1)))
    func writerPreservesVariantDocumentOrder() throws {
        let source = """
        #usda 1.0

        def Xform "Root" (
            variants = {
                string lod = "low"
            }
            prepend variantSets = "lod"
        )
        {
            variantSet "lod" = {
                "low" {
                    def Scope "Zebra"
                    {
                    }

                    def Scope "Alpha"
                    {
                    }
                }

                "high" {
                }
            }
        }
        """
        let expectedVariantPaths = [
            "/Root{lod}",
            "/Root{lod=low}",
            "/Root{lod=low}/Zebra",
            "/Root{lod=low}/Alpha",
            "/Root{lod=high}",
        ]
        let layer = try USDAReader().readLayer(from: source)
        #expect(layer.specs.filter { $0.path.contains("{") }.map(\.path) == expectedVariantPaths)

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)
        #expect(roundTripped.specs.filter { $0.path.contains("{") }.map(\.path) == expectedVariantPaths)
    }

    @Test(.timeLimit(.minutes(1)))
    func interleavedPrimBodyKeepsPerKindDocumentOrder() throws {
        let source = """
        #usda 1.0

        def Xform "Root"
        {
            double before = 1

            def Scope "First"
            {
            }

            double middle = 2

            variantSet "lod" = {
                "low" {
                }
            }

            def Scope "Second"
            {
            }

            double after = 3
        }
        """
        let layer = try USDAReader().readLayer(from: source)
        // The reader groups specs per prim (properties, variant sets, children)
        // while keeping document order within each kind.
        #expect(layer.spec(at: "/Root")?.fields["properties"]
            == .authored("/Root.before, /Root.middle, /Root.after"))
        #expect(layer.prims.map(\.path) == ["/Root", "/Root/First", "/Root/Second"])
        #expect(layer.specs.filter { $0.specType == .variant }.map(\.path) == ["/Root{lod=low}"])

        let written = try USDAWriter().string(for: layer)
        let roundTripped = try USDAReader().readLayer(from: written)
        #expect(roundTripped.spec(at: "/Root")?.fields["properties"]
            == layer.spec(at: "/Root")?.fields["properties"])
        #expect(roundTripped.prims.map(\.path) == ["/Root", "/Root/First", "/Root/Second"])
        #expect(roundTripped.specs.filter { $0.specType == .variant }.map(\.path) == ["/Root{lod=low}"])
    }

    // MARK: - Comments inside arrays

    @Test(.timeLimit(.minutes(1)))
    func arrayValuesSkipLineComments() throws {
        let source = """
        #usda 1.0
        (
            defaultPrim = "M"
            metersPerUnit = 1
            upAxis = "Z"
        )

        def Mesh "M"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0), # comment inside array
                (1, 1, 0)]
            int[] faceVertexCounts = [3, # another comment
                3]
            int[] faceVertexIndices = [0, 1, 2, # indices comment
                1, 3, 2]
            uniform token subdivisionScheme = "none"
        }
        """
        let scene = try USDAReader().read(from: source)
        let mesh = try #require(scene.meshes.first)
        #expect(mesh.points.count == 4)
        #expect(mesh.faceVertexCounts == [3, 3])
        #expect(mesh.faceVertexIndices == [0, 1, 2, 1, 3, 2])
    }

    // MARK: - metersPerUnit fallback

    @Test(.timeLimit(.minutes(1)))
    func metersPerUnitFallsBackToCentimetersForScenes() throws {
        let source = """
        #usda 1.0
        (
            defaultPrim = "M"
        )

        def Mesh "M"
        {
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            uniform token subdivisionScheme = "none"
        }
        """
        let scene = try USDAReader().read(from: source)
        // Upstream USD falls back to 0.01 (centimeters) when layer metadata
        // does not author metersPerUnit; the layer itself keeps it unauthored.
        #expect(scene.metersPerUnit == 0.01)

        let layer = try USDAReader().readLayer(from: source)
        #expect(layer.metersPerUnit == nil)
    }

    // MARK: - Export validation

    @Test(.timeLimit(.minutes(1)))
    func attributeSpecWithoutTypeNameCannotBeExported() {
        let layer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform"
            ),
            USDLayerSpec(
                path: "/Root.radius",
                specType: .attribute,
                fieldNames: ["default"],
                fields: ["default": .authored("1")]
            ),
        ])
        #expect(throws: USDError.self) {
            _ = try USDAWriter().string(for: layer)
        }
    }
}
