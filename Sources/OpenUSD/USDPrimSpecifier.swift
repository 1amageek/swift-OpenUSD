public enum USDPrimSpecifier: Sendable, Equatable, Hashable {
    case def
    case over
    case `class`
    case unknown(UInt64)

    public init(cratePayload: UInt64) {
        switch cratePayload {
        case 0:
            self = .def
        case 1:
            self = .over
        case 2:
            self = .class
        default:
            self = .unknown(cratePayload)
        }
    }
}
