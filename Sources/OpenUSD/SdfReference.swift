public struct SdfReference: Sendable, Equatable, Hashable {
    public var assetPath: String
    public var primPath: SdfPath?
    public var layerOffset: SdfLayerOffset
    public var customData: [String: SdfFieldValue]

    public init(
        assetPath: String,
        primPath: SdfPath? = nil,
        layerOffset: SdfLayerOffset = .identity,
        customData: [String: SdfFieldValue] = [:]
    ) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
        self.customData = customData
    }
}
