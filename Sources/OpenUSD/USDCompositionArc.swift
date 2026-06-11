public struct USDCompositionArc: Sendable, Equatable {
    public var assetPath: String
    public var sitePrimPath: String?
    public var targetPrimPath: String?
    public var layerOffset: SdfLayerOffset

    public init(
        assetPath: String,
        sitePrimPath: String? = nil,
        targetPrimPath: String? = nil,
        layerOffset: SdfLayerOffset = .identity
    ) {
        self.assetPath = assetPath
        self.sitePrimPath = sitePrimPath
        self.targetPrimPath = targetPrimPath
        self.layerOffset = layerOffset
    }
}
