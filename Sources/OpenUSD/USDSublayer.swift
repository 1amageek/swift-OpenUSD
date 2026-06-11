public struct USDSublayer: Sendable, Equatable, Hashable {
    public var assetPath: String
    public var layerOffset: SdfLayerOffset

    public init(assetPath: String, layerOffset: SdfLayerOffset = .identity) {
        self.assetPath = assetPath
        self.layerOffset = layerOffset
    }
}
