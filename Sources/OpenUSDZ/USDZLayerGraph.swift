import OpenUSD

public struct USDZLayerGraph: Sendable, Equatable {
    public struct Layer: Sendable, Equatable {
        public var path: String
        public var defaultPrim: String?
        public var metersPerUnit: Double?
        public var upAxis: USDUpAxis?
        public var composition: USDLayerComposition
        public var hasScene: Bool

        public init(
            path: String,
            defaultPrim: String? = nil,
            metersPerUnit: Double? = nil,
            upAxis: USDUpAxis? = nil,
            composition: USDLayerComposition = USDLayerComposition(),
            hasScene: Bool = false
        ) {
            self.path = path
            self.defaultPrim = defaultPrim
            self.metersPerUnit = metersPerUnit
            self.upAxis = upAxis
            self.composition = composition
            self.hasScene = hasScene
        }
    }

    public var rootPath: String
    public var layers: [Layer]

    public init(rootPath: String, layers: [Layer]) {
        self.rootPath = rootPath
        self.layers = layers
    }

    public var paths: [String] {
        layers.map(\.path)
    }
}
