public struct USDCReference: Sendable, Equatable {
    public var assetPath: String
    public var primPath: String
    public var layerOffset: USDCLayerOffset

    public init(assetPath: String, primPath: String, layerOffset: USDCLayerOffset = .identity) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
    }
}
