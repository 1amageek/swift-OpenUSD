public struct USDLayerComposition: Sendable, Equatable {
    public var subLayerAssetPaths: [String]
    public var references: [USDCompositionArc]
    public var payloads: [USDCompositionArc]

    public init(
        subLayerAssetPaths: [String] = [],
        references: [USDCompositionArc] = [],
        payloads: [USDCompositionArc] = []
    ) {
        self.subLayerAssetPaths = subLayerAssetPaths
        self.references = references
        self.payloads = payloads
    }

    public var assetPaths: [String] {
        subLayerAssetPaths + references.map(\.assetPath) + payloads.map(\.assetPath)
    }

    public var isEmpty: Bool {
        subLayerAssetPaths.isEmpty && references.isEmpty && payloads.isEmpty
    }
}
