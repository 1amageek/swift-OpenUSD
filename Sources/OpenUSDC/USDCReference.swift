import OpenUSD

public struct USDCReference: Sendable, Equatable {
    public var assetPath: String
    public var primPath: String
    public var layerOffset: USDLayerOffset

    public init(assetPath: String, primPath: String, layerOffset: USDLayerOffset = .identity) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
    }
}
