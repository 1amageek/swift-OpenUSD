public struct USDPrim: Sendable, Equatable, Hashable {
    public var path: SdfPath
    public var specifier: SdfSpecifier
    public var typeName: String?

    public init(path: SdfPath, specifier: SdfSpecifier, typeName: String? = nil) {
        self.path = path
        self.specifier = specifier
        self.typeName = typeName
    }

    public var name: String {
        path.name
    }

    public var isDefined: Bool {
        specifier == .def
    }

    public func isA(_ schemaTypeName: String, registry: USDSchemaRegistry = USDSchemaRegistry()) -> Bool {
        guard let typeName else {
            return false
        }
        return registry.isA(typeName, schemaTypeName)
    }
}
