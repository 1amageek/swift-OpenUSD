public struct USDCompositionArc: Sendable, Equatable {
    public var assetPath: String
    public var primPath: String?

    public init(assetPath: String, primPath: String? = nil) {
        self.assetPath = assetPath
        self.primPath = primPath
    }
}
