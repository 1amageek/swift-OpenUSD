import OpenUSD

public struct USDCPayload: Sendable, Equatable {
    public var assetPath: String
    public var primPath: String
    public var layerOffset: SdfLayerOffset

    public init(assetPath: String, primPath: String, layerOffset: SdfLayerOffset = .identity) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
    }
}
