struct USDCCrateValueRep: Sendable, Equatable, Hashable {
    static let isArrayBit: UInt64 = 1 << 63
    static let isInlinedBit: UInt64 = 1 << 62
    static let isCompressedBit: UInt64 = 1 << 61
    static let isArrayEditBit: UInt64 = 1 << 60
    static let payloadMask: UInt64 = (1 << 48) - 1

    var rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(type: USDCCrateValueType, isInlined: Bool, isArray: Bool, payload: UInt64) {
        rawValue = (isArray ? Self.isArrayBit : 0)
            | (isInlined ? Self.isInlinedBit : 0)
            | (UInt64(type.rawValue) << 48)
            | (payload & Self.payloadMask)
    }

    var isArray: Bool {
        rawValue & Self.isArrayBit != 0
    }

    var isInlined: Bool {
        rawValue & Self.isInlinedBit != 0
    }

    var isCompressed: Bool {
        rawValue & Self.isCompressedBit != 0
    }

    var isArrayEdit: Bool {
        rawValue & Self.isArrayEditBit != 0
    }

    var rawType: UInt8 {
        UInt8((rawValue >> 48) & 0xff)
    }

    var type: USDCCrateValueType? {
        USDCCrateValueType(rawValue: rawType)
    }

    var payload: UInt64 {
        rawValue & Self.payloadMask
    }
}
