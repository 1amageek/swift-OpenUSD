public struct USDSublayer: Sendable, Equatable, Hashable {
    public var assetPath: String
    public var layerOffset: USDLayerOffset

    public init(assetPath: String, layerOffset: USDLayerOffset = .identity) {
        self.assetPath = assetPath
        self.layerOffset = layerOffset
    }
}
