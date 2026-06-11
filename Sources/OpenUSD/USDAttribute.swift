public struct USDAttribute: Sendable, Equatable, Hashable {
    public var path: SdfPath
    public var name: String
    public var typeName: String

    public init(path: SdfPath, name: String, typeName: String) {
        self.path = path
        self.name = name
        self.typeName = typeName
    }
}
