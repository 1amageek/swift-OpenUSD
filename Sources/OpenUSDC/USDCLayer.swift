import OpenUSD

public struct USDCLayer: Sendable, Equatable {
    public var defaultPrim: String?
    public var metersPerUnit: Double?
    public var upAxis: USDUpAxis?
    public var specs: [USDCLayerSpec]
    public var primTransforms: [String: USDTransformMatrix4x4]

    public init(
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil,
        specs: [USDCLayerSpec] = [],
        primTransforms: [String: USDTransformMatrix4x4] = [:]
    ) {
        self.defaultPrim = defaultPrim
        self.metersPerUnit = metersPerUnit
        self.upAxis = upAxis
        self.specs = specs
        self.primTransforms = primTransforms
    }

    public var prims: [USDCLayerSpec] {
        specs.filter { $0.specType == .prim }
    }

    public func spec(at path: String) -> USDCLayerSpec? {
        specs.first { $0.path == path }
    }

    public var composition: USDLayerComposition {
        var references: [USDCompositionArc] = []
        var payloads: [USDCompositionArc] = []
        for spec in specs {
            for fieldName in spec.fieldNames {
                guard let field = spec.fields[fieldName] else {
                    continue
                }
                switch field {
                case .referenceListOperation(let operation):
                    references.append(contentsOf: operation.positiveItems.map {
                        USDCompositionArc(
                            assetPath: $0.assetPath,
                            sitePrimPath: spec.path,
                            targetPrimPath: $0.primPath,
                            layerOffset: $0.layerOffset
                        )
                    })
                case .payloadListOperation(let operation):
                    payloads.append(contentsOf: operation.positiveItems.map {
                        USDCompositionArc(
                            assetPath: $0.assetPath,
                            sitePrimPath: spec.path,
                            targetPrimPath: $0.primPath,
                            layerOffset: $0.layerOffset
                        )
                    })
                case .payload(let payload):
                    payloads.append(USDCompositionArc(
                        assetPath: payload.assetPath,
                        sitePrimPath: spec.path,
                        targetPrimPath: payload.primPath,
                        layerOffset: payload.layerOffset
                    ))
                default:
                    break
                }
            }
        }
        return USDLayerComposition(references: references, payloads: payloads)
    }
}

private extension USDCListOperation {
    var positiveItems: [Item] {
        explicitItems + addedItems + prependedItems + appendedItems
    }
}
