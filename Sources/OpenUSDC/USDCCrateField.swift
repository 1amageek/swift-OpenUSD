struct USDCCrateField: Sendable, Equatable, Hashable {
    var tokenIndex: UInt32
    var valueRep: USDCCrateValueRep

    init(tokenIndex: UInt32, valueRep: USDCCrateValueRep) {
        self.tokenIndex = tokenIndex
        self.valueRep = valueRep
    }
}
