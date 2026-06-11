public struct USDCUnmaterializedValue: Sendable, Equatable, Hashable {
    public var typeName: String
    public var rawType: UInt8
    public var payload: UInt64
    public var isArray: Bool
    public var isInlined: Bool
    public var isCompressed: Bool
    public var isArrayEdit: Bool

    public init(
        typeName: String,
        rawType: UInt8,
        payload: UInt64,
        isArray: Bool,
        isInlined: Bool,
        isCompressed: Bool,
        isArrayEdit: Bool
    ) {
        self.typeName = typeName
        self.rawType = rawType
        self.payload = payload
        self.isArray = isArray
        self.isInlined = isInlined
        self.isCompressed = isCompressed
        self.isArrayEdit = isArrayEdit
    }
}
