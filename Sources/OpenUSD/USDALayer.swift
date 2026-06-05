public struct USDALayer: Sendable, Equatable {
    public var defaultPrim: String?
    public var metersPerUnit: Double?
    public var upAxis: USDUpAxis?
    public var composition: USDLayerComposition
    public var specs: [USDLayerSpec]
    public var primTransforms: [String: USDTransformMatrix4x4]

    public init(
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil,
        composition: USDLayerComposition = USDLayerComposition(),
        specs: [USDLayerSpec] = [],
        primTransforms: [String: USDTransformMatrix4x4] = [:]
    ) {
        self.defaultPrim = defaultPrim
        self.metersPerUnit = metersPerUnit
        self.upAxis = upAxis
        self.composition = composition
        self.specs = specs
        self.primTransforms = primTransforms
    }

    public var prims: [USDLayerSpec] {
        specs.filter { $0.specType == .prim }
    }

    public func spec(at path: String) -> USDLayerSpec? {
        specs.first { $0.path == path }
    }
}
