import Foundation

public struct SdfLayer: Sendable, Equatable {
    public var identifier: String
    public var defaultPrim: String?
    public var metersPerUnit: Double?
    public var upAxis: USDUpAxis?
    public var primTransforms: [String: USDTransformMatrix4x4]
    public var resetXformStackPrimPaths: Set<String>
    public private(set) var specs: [SdfSpec]

    /// Maps each spec path to the index of its first occurrence in `specs`.
    /// The specs array remains the source of truth for document order.
    private var specIndexByPath: [SdfPath: Int]

    public init(
        identifier: String = "anon:swift-OpenUSD",
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil,
        specs: [SdfSpec] = [SdfSpec(path: .absoluteRoot, specType: .pseudoRoot)],
        primTransforms: [String: USDTransformMatrix4x4] = [:],
        resetXformStackPrimPaths: Set<String> = []
    ) {
        self.identifier = identifier
        self.defaultPrim = defaultPrim
        self.metersPerUnit = metersPerUnit
        self.upAxis = upAxis
        self.specs = specs
        self.specIndexByPath = Self.makeSpecIndex(for: specs)
        self.primTransforms = primTransforms
        self.resetXformStackPrimPaths = resetXformStackPrimPaths
    }

    public static func == (lhs: SdfLayer, rhs: SdfLayer) -> Bool {
        lhs.identifier == rhs.identifier
            && lhs.defaultPrim == rhs.defaultPrim
            && lhs.metersPerUnit == rhs.metersPerUnit
            && lhs.upAxis == rhs.upAxis
            && lhs.primTransforms == rhs.primTransforms
            && lhs.resetXformStackPrimPaths == rhs.resetXformStackPrimPaths
            && lhs.specs == rhs.specs
    }

    /// The composition view derived from the authored specs. The specs are
    /// the single source of truth: sublayers come from the root spec's
    /// typed subLayers/subLayerOffsets fields (raw authored subLayers text
    /// is not parsed), and arcs come from each prim spec's references and
    /// payload fields with list edits applied.
    public var composition: USDLayerComposition {
        var sublayers: [USDSublayer] = []
        var references: [USDCompositionArc] = []
        var payloads: [USDCompositionArc] = []
        for spec in specs {
            if spec.path == .absoluteRoot {
                sublayers.append(contentsOf: Self.authoredSublayers(of: spec))
            }
            if case .referenceListOperation(let operation)? = spec.fields["references"] {
                references.append(contentsOf: operation.effectiveItems.map {
                    Self.compositionArc(
                        assetPath: $0.assetPath,
                        primPath: $0.primPath,
                        layerOffset: $0.layerOffset,
                        sitePrimPath: spec.path
                    )
                })
            }
            switch spec.fields["payload"] {
            case .payloadListOperation(let operation)?:
                payloads.append(contentsOf: operation.effectiveItems.map {
                    Self.compositionArc(
                        assetPath: $0.assetPath,
                        primPath: $0.primPath,
                        layerOffset: $0.layerOffset,
                        sitePrimPath: spec.path
                    )
                })
            case .payload(let payload)?:
                payloads.append(Self.compositionArc(
                    assetPath: payload.assetPath,
                    primPath: payload.primPath,
                    layerOffset: payload.layerOffset,
                    sitePrimPath: spec.path
                ))
            default:
                break
            }
        }
        return USDLayerComposition(sublayers: sublayers, references: references, payloads: payloads)
    }

    private static func authoredSublayers(of spec: SdfSpec) -> [USDSublayer] {
        guard case .stringVector(let assetPaths)? = spec.fields["subLayers"] else {
            return []
        }
        let layerOffsets: [SdfLayerOffset]
        if case .layerOffsetVector(let offsets)? = spec.fields["subLayerOffsets"] {
            layerOffsets = offsets
        } else {
            layerOffsets = []
        }
        return assetPaths.enumerated().map { index, assetPath in
            USDSublayer(
                assetPath: assetPath,
                layerOffset: index < layerOffsets.count ? layerOffsets[index] : .identity
            )
        }
    }

    private static func compositionArc(
        assetPath: String,
        primPath: SdfPath?,
        layerOffset: SdfLayerOffset,
        sitePrimPath: SdfPath
    ) -> USDCompositionArc {
        USDCompositionArc(
            assetPath: assetPath,
            sitePrimPath: sitePrimPath.rawValue,
            targetPrimPath: primPath.flatMap { $0 == .absoluteRoot ? nil : $0.rawValue },
            layerOffset: layerOffset
        )
    }

    private static func makeSpecIndex(for specs: [SdfSpec]) -> [SdfPath: Int] {
        var index: [SdfPath: Int] = [:]
        index.reserveCapacity(specs.count)
        for (offset, spec) in specs.enumerated() where index[spec.path] == nil {
            index[spec.path] = offset
        }
        return index
    }

    public init(usdLayer: USDALayer, identifier: String = "anon:swift-OpenUSD") throws {
        var specs = try usdLayer.specs.map { try SdfSpec(layerSpec: $0) }
        Self.normalizeSublayerFields(in: &specs, sublayers: usdLayer.composition.sublayers)
        self.init(
            identifier: identifier,
            defaultPrim: usdLayer.defaultPrim,
            metersPerUnit: usdLayer.metersPerUnit,
            upAxis: usdLayer.upAxis,
            specs: specs,
            primTransforms: usdLayer.primTransforms,
            resetXformStackPrimPaths: usdLayer.resetXformStackPrimPaths
        )
    }

    /// Replaces the USDA parser's raw authored subLayers text on the root
    /// spec with the typed subLayers/subLayerOffsets fields, treating the
    /// source layer's parsed sublayers as authoritative, so that the derived
    /// `composition` view can read them back.
    private static func normalizeSublayerFields(in specs: inout [SdfSpec], sublayers: [USDSublayer]) {
        guard let rootIndex = specs.firstIndex(where: { $0.path == .absoluteRoot }) else {
            guard !sublayers.isEmpty else {
                return
            }
            var root = SdfSpec(path: .absoluteRoot, specType: .pseudoRoot)
            setSublayerFields(sublayers, in: &root)
            specs.insert(root, at: 0)
            return
        }
        guard !sublayers.isEmpty || specs[rootIndex].fields["subLayers"] != nil else {
            return
        }
        setSublayerFields(sublayers, in: &specs[rootIndex])
    }

    private static func setSublayerFields(_ sublayers: [USDSublayer], in spec: inout SdfSpec) {
        spec.setField(.stringVector(sublayers.map(\.assetPath)), for: "subLayers")
        if sublayers.contains(where: { !$0.layerOffset.isIdentity }) {
            spec.setField(.layerOffsetVector(sublayers.map(\.layerOffset)), for: "subLayerOffsets")
        } else {
            spec.clearField(named: "subLayerOffsets")
        }
    }

    /// Creates a fresh anonymous layer. Each call generates a unique
    /// identifier so anonymous layers never collide in caches or
    /// providers that key layers by identifier.
    public static func createAnonymous(tag: String = "swift-OpenUSD") -> SdfLayer {
        SdfLayer(identifier: "anon:\(UUID().uuidString):\(tag)")
    }

    public static func importUSDA(from text: String, identifier: String = "anon:swift-OpenUSD") throws -> SdfLayer {
        try SdfLayer(usdLayer: USDAReader().readLayer(from: text), identifier: identifier)
    }

    public static func importUSDA(from data: Data, identifier: String = "anon:swift-OpenUSD") throws -> SdfLayer {
        try SdfLayer(usdLayer: USDAReader().readLayer(from: data), identifier: identifier)
    }

    public mutating func importUSDA(from text: String) throws {
        self = try SdfLayer.importUSDA(from: text, identifier: identifier)
    }

    public mutating func importUSDA(from data: Data) throws {
        self = try SdfLayer.importUSDA(from: data, identifier: identifier)
    }

    public mutating func clear() {
        defaultPrim = nil
        metersPerUnit = nil
        upAxis = nil
        specs = [SdfSpec(path: .absoluteRoot, specType: .pseudoRoot)]
        specIndexByPath = Self.makeSpecIndex(for: specs)
        primTransforms = [:]
        resetXformStackPrimPaths = []
    }

    /// Authors the typed subLayers/subLayerOffsets fields on the root spec.
    public mutating func setSublayers(_ sublayers: [USDSublayer]) throws {
        guard var root = spec(at: .absoluteRoot) else {
            throw USDError.invalidData("SdfLayer has no pseudo-root spec to author sublayers on.")
        }
        Self.setSublayerFields(sublayers, in: &root)
        setSpec(root)
    }

    public func exportUSDA() throws -> String {
        try USDAWriter().string(for: exportLayer())
    }

    public func exportUSDAData() throws -> Data {
        try USDAWriter().data(for: exportLayer())
    }

    public func spec(at path: SdfPath) -> SdfSpec? {
        guard let index = specIndexByPath[path] else {
            return nil
        }
        return specs[index]
    }

    public func spec(at path: String) throws -> SdfSpec? {
        spec(at: try SdfPath(path))
    }

    public func listFields(at path: SdfPath) -> [String] {
        spec(at: path)?.listFields() ?? []
    }

    public func validate() throws {
        try validateDefaultPrim()
        try validateSpecs()
        try validateSpecContainment()
    }

    public func field(named name: String, at path: SdfPath) -> SdfFieldValue? {
        spec(at: path)?.field(named: name)
    }

    public mutating func setSpec(_ spec: SdfSpec) {
        if let index = specIndexByPath[spec.path] {
            specs[index] = spec
        } else {
            specIndexByPath[spec.path] = specs.count
            specs.append(spec)
        }
    }

    @discardableResult
    public mutating func removeSpec(at path: SdfPath) -> SdfSpec? {
        guard let index = specIndexByPath[path] else {
            return nil
        }
        let removed = specs.remove(at: index)
        specIndexByPath = Self.makeSpecIndex(for: specs)
        return removed
    }

    public mutating func setField(_ value: SdfFieldValue, for name: String, at path: SdfPath) throws {
        try validateFieldName(name)
        guard var spec = spec(at: path) else {
            throw USDError.invalidData("SdfLayer has no spec at \(path.rawValue).")
        }
        spec.setField(value, for: name)
        setSpec(spec)
    }

    public mutating func clearField(named name: String, at path: SdfPath) throws {
        try validateFieldName(name)
        guard var spec = spec(at: path) else {
            throw USDError.invalidData("SdfLayer has no spec at \(path.rawValue).")
        }
        spec.clearField(named: name)
        setSpec(spec)
    }

    public func toUSDALayer() -> USDALayer {
        USDALayer(
            defaultPrim: defaultPrim,
            metersPerUnit: metersPerUnit,
            upAxis: upAxis,
            composition: composition,
            specs: specs.map { $0.toUSDLayerSpec() },
            primTransforms: primTransforms,
            resetXformStackPrimPaths: resetXformStackPrimPaths
        )
    }

    private func exportLayer() throws -> USDALayer {
        try validateUSDAExportSupport()
        var layer = toUSDALayer()
        applySublayerExportText(to: &layer)
        return layer
    }

    /// Rewrites the typed subLayers/subLayerOffsets root fields into the
    /// inline USDA asset-list syntax. Raw authored subLayers text is left
    /// untouched and passes through to the writer verbatim.
    private func applySublayerExportText(to layer: inout USDALayer) {
        guard let rootSpec = spec(at: .absoluteRoot),
              case .stringVector? = rootSpec.fields["subLayers"],
              var root = layer.spec(at: "/") else {
            return
        }
        root.fields["subLayers"] = .authored(Self.sublayerListText(composition.sublayers))
        root.fields.removeValue(forKey: "subLayerOffsets")
        root.fieldNames.removeAll { $0 == "subLayerOffsets" }
        layer.setSpec(root)
    }

    private static func sublayerListText(_ sublayers: [USDSublayer]) -> String {
        let items = sublayers.map { sublayer in
            SdfFieldValue.assetPathText(sublayer.assetPath)
                + SdfFieldValue.layerOffsetSuffix(sublayer.layerOffset)
        }
        return "[\(items.joined(separator: ", "))]"
    }

    private func validateDefaultPrim() throws {
        guard let defaultPrim else {
            return
        }
        let defaultPrimPath = try SdfPath("/\(defaultPrim)")
        guard defaultPrimPath.kind == .prim,
              defaultPrimPath.parentPath == .absoluteRoot else {
            throw USDError.invalidData("SdfLayer defaultPrim \(defaultPrim) is not a root prim name.")
        }
        if specs.contains(where: { $0.specType == .prim }) {
            guard spec(at: defaultPrimPath)?.specType == .prim else {
                throw USDError.invalidData("SdfLayer defaultPrim \(defaultPrim) has no matching root prim spec.")
            }
        }
    }

    private func validateSpecs() throws {
        var paths: Set<SdfPath> = []
        for spec in specs {
            try spec.validate()
            guard paths.insert(spec.path).inserted else {
                throw USDError.invalidData("SdfLayer contains duplicate spec path \(spec.path.rawValue).")
            }
        }
    }

    private func validateSpecContainment() throws {
        for spec in specs {
            switch spec.specType {
            case .pseudoRoot:
                continue
            case .prim:
                guard let parentPath = spec.path.parentPath else {
                    continue
                }
                if parentPath == .absoluteRoot {
                    continue
                }
                try requireContainerSpec(at: parentPath, for: spec)
            case .attribute, .relationship:
                guard let parentPath = spec.path.primPath else {
                    throw USDError.invalidData("SdfLayer property spec \(spec.path.rawValue) has no parent prim path.")
                }
                try requireContainerSpec(at: parentPath, for: spec)
            case .connection:
                try requirePropertySpec(for: spec, expectedParentType: .attribute, targetFieldName: "connectionPaths")
            case .relationshipTarget:
                try requirePropertySpec(for: spec, expectedParentType: .relationship, targetFieldName: "targetPaths")
            case .variantSet:
                guard let parentPath = spec.path.parentPath else {
                    throw USDError.invalidData("SdfLayer variant set \(spec.path.rawValue) has no parent prim path.")
                }
                try requireContainerSpec(at: parentPath, for: spec)
            case .variant:
                let variantSetPath = try variantSetPath(forVariantPath: spec.path)
                guard self.spec(at: variantSetPath)?.specType == .variantSet else {
                    throw USDError.invalidData("SdfLayer variant \(spec.path.rawValue) has no parent variant set spec.")
                }
            case .expression, .mapper, .mapperArgument:
                throw USDError.unsupportedFeature("SdfLayer spec type \(spec.specType) is not supported by swift-OpenUSD authoring yet.")
            }
        }
    }

    private func requireContainerSpec(at path: SdfPath, for childSpec: SdfSpec) throws {
        let expectedType: SdfSpecType = isVariantSelectionRoot(path) ? .variant : .prim
        guard spec(at: path)?.specType == expectedType else {
            throw USDError.invalidData(
                "SdfLayer spec \(childSpec.path.rawValue) has no parent \(expectedType) spec at \(path.rawValue)."
            )
        }
    }

    private func requirePropertySpec(
        for targetSpec: SdfSpec,
        expectedParentType: SdfSpecType,
        targetFieldName: String
    ) throws {
        guard let propertyPath = targetSpec.path.propertyPath else {
            throw USDError.invalidData("SdfLayer target spec \(targetSpec.path.rawValue) has no property path.")
        }
        guard spec(at: propertyPath)?.specType == expectedParentType else {
            throw USDError.invalidData(
                "SdfLayer target spec \(targetSpec.path.rawValue) has no parent \(expectedParentType) spec at \(propertyPath.rawValue)."
            )
        }
        guard let targetPath = targetSpec.path.targetPath else {
            throw USDError.invalidData("SdfLayer target spec \(targetSpec.path.rawValue) has no target path.")
        }
        guard propertySpec(at: propertyPath, containsTarget: targetPath, fieldName: targetFieldName) else {
            throw USDError.invalidData(
                "SdfLayer target spec \(targetSpec.path.rawValue) is not represented by \(targetFieldName) on \(propertyPath.rawValue)."
            )
        }
    }

    private func propertySpec(at propertyPath: SdfPath, containsTarget targetPath: SdfPath, fieldName: String) -> Bool {
        guard let property = spec(at: propertyPath),
              case .pathListOperation(let operation)? = property.fields[fieldName] else {
            return false
        }
        return listOperation(operation, contains: targetPath)
    }

    private func listOperation<Item: Sendable & Equatable & Hashable>(
        _ operation: SdfListOperation<Item>,
        contains item: Item
    ) -> Bool {
        operation.explicitItems.contains(item)
            || operation.addedItems.contains(item)
            || operation.prependedItems.contains(item)
            || operation.appendedItems.contains(item)
            || operation.deletedItems.contains(item)
            || operation.orderedItems.contains(item)
    }

    private func variantSetPath(forVariantPath path: SdfPath) throws -> SdfPath {
        guard let variantSetPath = path.variantSetPath else {
            throw USDError.invalidData("SdfLayer variant path \(path.rawValue) is malformed.")
        }
        return variantSetPath
    }

    private func isVariantSelectionRoot(_ path: SdfPath) -> Bool {
        path.kind == .variantSelection
    }

    private func validateFieldName(_ name: String) throws {
        guard !name.isEmpty else {
            throw USDError.invalidData("SdfLayer field name must not be empty.")
        }
        guard !name.contains(where: { $0.isWhitespace || $0 == "=" || $0 == "(" || $0 == ")" }) else {
            throw USDError.invalidData("SdfLayer field name \(name) is invalid.")
        }
    }
}
