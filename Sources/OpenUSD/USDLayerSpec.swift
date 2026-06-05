public struct USDLayerSpec: Sendable, Equatable, Hashable {
    public var path: String
    public var specType: USDSpecType
    public var specifier: USDPrimSpecifier?
    public var typeName: String?
    public var fieldNames: [String]

    public init(
        path: String,
        specType: USDSpecType,
        specifier: USDPrimSpecifier? = nil,
        typeName: String? = nil,
        fieldNames: [String] = []
    ) {
        self.path = path
        self.specType = specType
        self.specifier = specifier
        self.typeName = typeName
        self.fieldNames = fieldNames
    }
}
