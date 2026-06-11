import OpenUSD

public extension SdfLayer {
    init(usdcLayer: USDCLayer, identifier: String = "anon:swift-OpenUSD") throws {
        self.init(
            identifier: identifier,
            defaultPrim: usdcLayer.defaultPrim,
            metersPerUnit: usdcLayer.metersPerUnit,
            upAxis: usdcLayer.upAxis,
            specs: try usdcLayer.specs.map { try SdfSpec(usdcLayerSpec: $0) },
            primTransforms: usdcLayer.primTransforms,
            resetXformStackPrimPaths: usdcLayer.resetXformStackPrimPaths
        )
    }
}
