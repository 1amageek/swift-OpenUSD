import OpenUSD

/// Builds an in-memory layer provider from USDA layers authored in tests,
/// converting each layer to the Sdf data model keyed by its identifier.
func makeInMemoryProvider(_ layers: [String: USDALayer]) throws -> USDInMemoryLayerProvider {
    var sdfLayers: [String: SdfLayer] = [:]
    for (identifier, layer) in layers {
        sdfLayers[identifier] = try SdfLayer(usdLayer: layer, identifier: identifier)
    }
    return USDInMemoryLayerProvider(layers: sdfLayers)
}
