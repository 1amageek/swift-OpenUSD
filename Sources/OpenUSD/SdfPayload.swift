public struct SdfPayload: Sendable, Equatable, Hashable {
    public var assetPath: String
    public var primPath: SdfPath?
    public var layerOffset: SdfLayerOffset

    public init(assetPath: String, primPath: SdfPath? = nil, layerOffset: SdfLayerOffset = .identity) {
        self.assetPath = assetPath
        self.primPath = primPath
        self.layerOffset = layerOffset
    }
}
