public struct USDLayerSpec: Sendable, Equatable, Hashable {
    public var path: String
    public var specType: SdfSpecType
    public var specifier: SdfSpecifier?
    public var typeName: String?
    public var fieldNames: [String]
    public var fields: [String: USDLayerFieldValue]

    public init(
        path: String,
        specType: SdfSpecType,
        specifier: SdfSpecifier? = nil,
        typeName: String? = nil,
        fieldNames: [String] = [],
        fields: [String: USDLayerFieldValue] = [:]
    ) {
        self.path = path
        self.specType = specType
        self.specifier = specifier
        self.typeName = typeName
        self.fieldNames = fieldNames.isEmpty ? fields.keys.sorted() : fieldNames
        self.fields = fields
    }
}
