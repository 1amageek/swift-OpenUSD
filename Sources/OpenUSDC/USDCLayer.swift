import OpenUSD

public struct USDCLayer: Sendable, Equatable {
    public var defaultPrim: String?
    public var metersPerUnit: Double?
    public var upAxis: USDUpAxis?
    public var specs: [USDCLayerSpec]
    public var primTransforms: [String: USDTransformMatrix4x4]
    public var resetXformStackPrimPaths: Set<String>

    public init(
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil,
        specs: [USDCLayerSpec] = [],
        primTransforms: [String: USDTransformMatrix4x4] = [:],
        resetXformStackPrimPaths: Set<String> = []
    ) {
        self.defaultPrim = defaultPrim
        self.metersPerUnit = metersPerUnit
        self.upAxis = upAxis
        self.specs = specs
        self.primTransforms = primTransforms
        self.resetXformStackPrimPaths = resetXformStackPrimPaths
    }

    public var prims: [USDCLayerSpec] {
        specs.filter { $0.specType == .prim }
    }

    public func spec(at path: String) -> USDCLayerSpec? {
        specs.first { $0.path == path }
    }

    public var composition: USDLayerComposition {
        var sublayers: [USDSublayer] = []
        var references: [USDCompositionArc] = []
        var payloads: [USDCompositionArc] = []
        for spec in specs {
            if spec.path == "/" {
                sublayers.append(contentsOf: layerSublayers(from: spec))
            }
            for fieldName in spec.fieldNames {
                guard let field = spec.fields[fieldName] else {
                    continue
                }
                switch field {
                case .referenceListOperation(let operation):
                    references.append(contentsOf: operation.effectiveItems.map {
                        USDCompositionArc(
                            assetPath: $0.assetPath,
                            sitePrimPath: spec.path,
                            targetPrimPath: compositionTargetPrimPath(from: $0.primPath),
                            layerOffset: $0.layerOffset
                        )
                    })
                case .payloadListOperation(let operation):
                    payloads.append(contentsOf: operation.effectiveItems.map {
                        USDCompositionArc(
                            assetPath: $0.assetPath,
                            sitePrimPath: spec.path,
                            targetPrimPath: compositionTargetPrimPath(from: $0.primPath),
                            layerOffset: $0.layerOffset
                        )
                    })
                case .payload(let payload):
                    payloads.append(USDCompositionArc(
                        assetPath: payload.assetPath,
                        sitePrimPath: spec.path,
                        targetPrimPath: compositionTargetPrimPath(from: payload.primPath),
                        layerOffset: payload.layerOffset
                    ))
                default:
                    break
                }
            }
        }
        return USDLayerComposition(sublayers: sublayers, references: references, payloads: payloads)
    }

    private func layerSublayers(from spec: USDCLayerSpec) -> [USDSublayer] {
        guard case .stringVector(let assetPaths)? = spec.fields["subLayers"] else {
            return []
        }
        let layerOffsets: [USDLayerOffset]
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

    private func compositionTargetPrimPath(from path: String) -> String? {
        path.isEmpty || path == "/" ? nil : path
    }
}

private extension USDCListOperation {
    var effectiveItems: [Item] {
        var items: [Item] = []
        if isExplicit {
            appendUnique(explicitItems, to: &items)
        } else {
            // Effective composition arcs are this op applied to an empty base list.
            appendUnique(prependedItems, to: &items)
            appendUnique(addedItems, to: &items)
            appendUnique(appendedItems, to: &items)
        }
        guard !orderedItems.isEmpty else {
            return items
        }
        var ordered: [Item] = []
        for orderedItem in orderedItems {
            guard let item = items.first(where: { $0 == orderedItem }) else {
                continue
            }
            appendUnique([item], to: &ordered)
        }
        appendUnique(items, to: &ordered)
        return ordered
    }

    private func appendUnique(_ newItems: [Item], to items: inout [Item]) {
        for item in newItems {
            guard !items.contains(item) else {
                continue
            }
            items.append(item)
        }
    }
}
