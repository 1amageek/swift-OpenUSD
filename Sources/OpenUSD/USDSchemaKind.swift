public enum USDSchemaKind: String, Sendable, Equatable, Hashable {
    case invalid
    case abstractBase
    case abstractTyped
    case concreteTyped
    case nonAppliedAPI
    case singleApplyAPI
    case multipleApplyAPI

    public var isConcrete: Bool {
        self == .concreteTyped
    }

    public var isAppliedAPI: Bool {
        self == .singleApplyAPI || self == .multipleApplyAPI
    }
}
