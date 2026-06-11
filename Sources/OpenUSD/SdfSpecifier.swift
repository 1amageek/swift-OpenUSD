public enum SdfSpecifier: Sendable, Equatable, Hashable {
    case def
    case over
    case `class`
    case unknown(UInt64)
}
