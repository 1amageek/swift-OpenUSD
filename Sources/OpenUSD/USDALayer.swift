public struct USDALayer: Sendable, Equatable {
    public var defaultPrim: String?
    public var metersPerUnit: Double?
    public var upAxis: USDUpAxis?
    public var composition: USDLayerComposition
    public var primTransforms: [String: USDTransformMatrix4x4]

    public init(
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil,
        composition: USDLayerComposition = USDLayerComposition(),
        primTransforms: [String: USDTransformMatrix4x4] = [:]
    ) {
        self.defaultPrim = defaultPrim
        self.metersPerUnit = metersPerUnit
        self.upAxis = upAxis
        self.composition = composition
        self.primTransforms = primTransforms
    }
}
