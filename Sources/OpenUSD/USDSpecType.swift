public enum USDSpecType: Sendable, Equatable, Hashable, CaseIterable {
    case attribute
    case connection
    case expression
    case mapper
    case mapperArgument
    case prim
    case pseudoRoot
    case relationship
    case relationshipTarget
    case variant
    case variantSet
}
