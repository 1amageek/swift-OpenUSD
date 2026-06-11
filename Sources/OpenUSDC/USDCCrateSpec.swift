struct USDCCrateSpec: Sendable, Equatable, Hashable {
    var pathIndex: UInt32
    var fieldSetIndex: UInt32
    var specType: USDCCrateSpecType

    init(pathIndex: UInt32, fieldSetIndex: UInt32, specType: USDCCrateSpecType) {
        self.pathIndex = pathIndex
        self.fieldSetIndex = fieldSetIndex
        self.specType = specType
    }
}
