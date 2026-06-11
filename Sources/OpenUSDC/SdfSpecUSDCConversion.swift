import OpenUSD

public extension SdfSpec {
    init(usdcLayerSpec: USDCLayerSpec) throws {
        let fields = try usdcLayerSpec.fields.mapValues { try SdfFieldValue(usdcLayerFieldValue: $0) }
        self.init(
            path: try SdfPath(usdcLayerSpec.path),
            specType: usdcLayerSpec.specType,
            specifier: usdcLayerSpec.specifier,
            typeName: usdcLayerSpec.typeName,
            fieldNames: usdcLayerSpec.fieldNames,
            fields: fields
        )
    }
}
