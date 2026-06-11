public struct USDRelationship: Sendable, Equatable, Hashable {
    public var path: SdfPath
    public var name: String

    public init(path: SdfPath, name: String) {
        self.path = path
        self.name = name
    }
}
