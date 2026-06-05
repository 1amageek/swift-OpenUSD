public struct USDCLayerOffset: Sendable, Equatable {
    public var offset: Double
    public var scale: Double

    public init(offset: Double = 0, scale: Double = 1) {
        self.offset = offset
        self.scale = scale
    }

    public static let identity = USDCLayerOffset()
}
