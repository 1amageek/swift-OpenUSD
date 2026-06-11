import Foundation
import Testing
import OpenUSD

@Suite("Sdf Core Model")
struct SdfCoreModelTests {
    @Test(.timeLimit(.minutes(1)))
    func sdfPathKindIsDeterminedByFinalPathElement() throws {
        #expect(try SdfPath("/Root{v=x}/Child").kind == .prim)
        #expect(try SdfPath("/Root{v=x}/Child/Grandchild").kind == .prim)
        #expect(try SdfPath("/Root{v=x}").kind == .variantSelection)
        #expect(try SdfPath("/Root{v}").kind == .variantSet)
        #expect(try SdfPath("/Root{v=x}{lod}").kind == .variantSet)
        #expect(try SdfPath("/Root{v=x}{lod=low}").kind == .variantSelection)
        #expect(try SdfPath("/Root{v=x}/Child.size").kind == .property)
        #expect(try SdfPath("/Root.rel[/Target]").kind == .propertyTarget)
        #expect(SdfPath.absoluteRoot.kind == .pseudoRoot)
        #expect(try SdfPath("/Root").kind == .prim)
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfPathVariantNavigationFollowsFinalElement() throws {
        let selection = try SdfPath("/Root{v=x}")
        let variantPrim = try SdfPath("/Root{v=x}/Child")

        #expect(selection.parentPath == (try SdfPath("/Root")))
        #expect(selection.variantSetPath == (try SdfPath("/Root{v}")))
        #expect(variantPrim.parentPath == selection)
        #expect(variantPrim.variantSetPath == nil)
        #expect(try SdfPath("/Root{v=x}{lod=low}").variantSetPath == (try SdfPath("/Root{v=x}{lod}")))
        #expect(try SdfPath("/Root{v}").variantSetPath == nil)
        #expect(try SdfPath("/Root").variantSetPath == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfPathHasPrefixIsNamespaceAware() throws {
        let foo = try SdfPath("/Foo")
        let fooBar = try SdfPath("/FooBar")
        let nested = try SdfPath("/A/B")
        let property = try SdfPath("/A/B.attr")
        let namespacedProperty = try SdfPath("/A/B.attr:suffix")
        let target = try SdfPath("/A/B.attr[/Target]")
        let variantSelection = try SdfPath("/Foo{v=x}")

        #expect(!fooBar.hasPrefix(foo))
        #expect(property.hasPrefix(nested))
        #expect(try SdfPath("/A/B/C").hasPrefix(nested))
        #expect(target.hasPrefix(property))
        #expect(target.hasPrefix(nested))
        #expect(!namespacedProperty.hasPrefix(property))
        #expect(variantSelection.hasPrefix(foo))
        #expect(nested.hasPrefix(nested))
        #expect(nested.hasPrefix(.absoluteRoot))
        #expect(!(try SdfPath("Relative/Child").hasPrefix(.absoluteRoot)))
        #expect(try SdfPath("Relative/Child").hasPrefix(try SdfPath("Relative")))
        #expect(!nested.hasPrefix(property))
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfPathReplacingPrefixRewritesNamespace() throws {
        let source = try SdfPath("/A/B.attr")

        #expect(try source.replacingPrefix(try SdfPath("/A"), with: try SdfPath("/X/Y")) == (try SdfPath("/X/Y/B.attr")))
        #expect(try source.replacingPrefix(try SdfPath("/A/B"), with: try SdfPath("/C")) == (try SdfPath("/C.attr")))
        #expect(try source.replacingPrefix(try SdfPath("/Other"), with: try SdfPath("/X")) == nil)
        #expect(try source.replacingPrefix(source, with: try SdfPath("/Z.other")) == (try SdfPath("/Z.other")))
        #expect(try SdfPath("/A/B").replacingPrefix(try SdfPath("/A"), with: .absoluteRoot) == (try SdfPath("/B")))
        #expect(try SdfPath("/B").replacingPrefix(.absoluteRoot, with: try SdfPath("/A")) == (try SdfPath("/A/B")))
        #expect(throws: USDError.self) {
            _ = try SdfPath("/A.attr").replacingPrefix(try SdfPath("/A"), with: .absoluteRoot)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfPathAppendingVariantSelectionAndTargetValidateInputs() throws {
        let root = try SdfPath("/Root")
        let selection = try root.appendingVariantSelection("v", "x")

        #expect(selection == (try SdfPath("/Root{v=x}")))
        #expect(selection.kind == .variantSelection)
        #expect(try selection.appendingVariantSelection("lod", "low") == (try SdfPath("/Root{v=x}{lod=low}")))

        #expect(throws: USDError.self) {
            _ = try root.appendingVariantSelection("not a set", "x")
        }
        #expect(throws: USDError.self) {
            _ = try root.appendingVariantSelection("v", "")
        }
        #expect(throws: USDError.self) {
            _ = try SdfPath("/Root.attr").appendingVariantSelection("v", "x")
        }

        let relationship = try root.appendingProperty("rel")
        let target = try relationship.appendingTarget(try SdfPath("/Target"))

        #expect(target == (try SdfPath("/Root.rel[/Target]")))
        #expect(target.kind == .propertyTarget)

        #expect(throws: USDError.self) {
            _ = try root.appendingTarget(try SdfPath("/Target"))
        }
        #expect(throws: USDError.self) {
            _ = try relationship.appendingTarget(target)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfSpecPathCompatibilityFollowsCorrectedKinds() throws {
        try SdfSpec(path: "/Root{v=x}/Child", specType: .prim, specifier: .def).validate()
        try SdfSpec(path: "/Root{v=x}", specType: .variant).validate()
        try SdfSpec(path: "/Root{v}", specType: .variantSet).validate()

        #expect(throws: USDError.self) {
            try SdfSpec(path: "/Root{v=x}", specType: .prim, specifier: .def).validate()
        }
        #expect(throws: USDError.self) {
            try SdfSpec(path: "/Root{v=x}/Child", specType: .variant).validate()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sdfLayerSpecLookupStaysConsistentAcrossMutations() throws {
        var layer = SdfLayer.createAnonymous()
        let first = try SdfSpec(path: "/First", specType: .prim, specifier: .def, typeName: "Xform")
        let second = try SdfSpec(path: "/Second", specType: .prim, specifier: .def, typeName: "Scope")
        let third = try SdfSpec(path: "/Third", specType: .prim, specifier: .def)
        layer.setSpec(first)
        layer.setSpec(second)
        layer.setSpec(third)

        #expect(layer.specs.map(\.path.rawValue) == ["/", "/First", "/Second", "/Third"])
        #expect(layer.spec(at: first.path) == first)
        #expect(layer.spec(at: second.path) == second)

        var updatedSecond = second
        updatedSecond.typeName = "Xform"
        layer.setSpec(updatedSecond)

        #expect(layer.specs.map(\.path.rawValue) == ["/", "/First", "/Second", "/Third"])
        #expect(layer.spec(at: second.path)?.typeName == "Xform")

        let removed = layer.removeSpec(at: second.path)

        #expect(removed == updatedSecond)
        #expect(layer.spec(at: second.path) == nil)
        #expect(layer.spec(at: first.path) == first)
        #expect(layer.spec(at: third.path) == third)
        #expect(layer.removeSpec(at: second.path) == nil)

        layer.setSpec(second)

        #expect(layer.specs.map(\.path.rawValue) == ["/", "/First", "/Third", "/Second"])
        #expect(layer.spec(at: second.path) == second)

        try layer.setField(.string("hello"), for: "documentation", at: third.path)

        #expect(layer.field(named: "documentation", at: third.path) == .string("hello"))

        try layer.clearField(named: "documentation", at: third.path)

        #expect(layer.field(named: "documentation", at: third.path) == nil)

        layer.clear()

        #expect(layer.specs.map(\.path.rawValue) == ["/"])
        #expect(layer.spec(at: first.path) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStagePreservesPropertyOrderListOperationForm() throws {
        let existingOperation = SdfListOperation(appendedItems: ["/Root.existing"])
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                typeName: "Xform",
                fieldNames: ["specifier", "properties"],
                fields: [
                    "specifier": .authored("def"),
                    "properties": .pathListOperation(existingOperation),
                ]
            ),
            USDLayerSpec(
                path: "/Root.existing",
                specType: .attribute,
                typeName: "double",
                fieldNames: ["typeName"],
                fields: ["typeName": .authored("double")]
            ),
        ])
        var stage = USDStage(rootLayer: rootLayer)

        _ = try stage.createAttribute(at: SdfPath("/Root"), name: "size", typeName: "double")

        guard case .pathListOperation(let operation)? = stage.rootLayer.spec(at: "/Root")?.fields["properties"] else {
            Issue.record("USDStage rewrote the properties list operation into another storage form.")
            return
        }
        #expect(operation.effectiveItems == ["/Root.existing", "/Root.size"])

        _ = try stage.createRelationship(at: SdfPath("/Root"), name: "size")

        guard case .pathListOperation(let unchanged)? = stage.rootLayer.spec(at: "/Root")?.fields["properties"] else {
            Issue.record("USDStage rewrote the properties list operation into another storage form.")
            return
        }
        #expect(unchanged.effectiveItems == ["/Root.existing", "/Root.size"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStagePreservesExplicitPropertyOrderListOperationForm() throws {
        let rootLayer = USDALayer(specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(
                path: "/Root",
                specType: .prim,
                specifier: .def,
                fieldNames: ["specifier", "properties"],
                fields: [
                    "specifier": .authored("def"),
                    "properties": .pathListOperation(SdfListOperation(
                        isExplicit: true,
                        explicitItems: ["/Root.first"]
                    )),
                ]
            ),
        ])
        var stage = USDStage(rootLayer: rootLayer)

        _ = try stage.createAttribute(at: SdfPath("/Root"), name: "second", typeName: "double")

        guard case .pathListOperation(let operation)? = stage.rootLayer.spec(at: "/Root")?.fields["properties"] else {
            Issue.record("USDStage rewrote the explicit properties list operation into another storage form.")
            return
        }
        #expect(operation.isExplicit)
        #expect(operation.explicitItems == ["/Root.first", "/Root.second"])
    }

    @Test(.timeLimit(.minutes(1)))
    func usdStageAuthoringKeepsSpecLookupConsistent() throws {
        var stage = USDStage.createInMemory()
        _ = try stage.definePrim(at: SdfPath("/World/Geom"), typeName: "Scope")
        _ = try stage.overridePrim(at: SdfPath("/World/Geom"))
        _ = try stage.createAttribute(at: SdfPath("/World/Geom"), name: "size", typeName: "double", defaultValue: "1")
        try stage.setAttributeDefault(at: SdfPath("/World/Geom.size"), value: "2")

        let worldPath = try SdfPath("/World")
        let geomPath = try SdfPath("/World/Geom")
        #expect(stage.prim(at: worldPath) != nil)
        #expect(stage.prim(at: geomPath)?.specifier == .over)
        #expect(stage.rootLayer.spec(at: "/World/Geom.size")?.fields["default"] == .authored("2"))
        #expect(stage.rootLayer.specs.filter { $0.path == "/World/Geom" }.count == 1)
        #expect(stage.rootLayer.spec(at: "/World/Geom")?.fields["properties"] == .authored("/World/Geom.size"))
    }
}
