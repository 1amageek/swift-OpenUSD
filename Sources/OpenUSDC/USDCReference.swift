import OpenUSD

public struct USDCReference: Sendable, Equatable {
    public var assetPath: String
    public var primPath: String
    public var layerOffset: USDLayerOffset
    public var customData: [String: USDCLayerFieldValue]

    public init(
        assetPath: String,
        primPath: String,
        layerOffset: USDLayerOffset = .identity,
        customData: [String: USDCLayerFieldValue] = [:]
    ) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
        self.customData = customData
    }
}
