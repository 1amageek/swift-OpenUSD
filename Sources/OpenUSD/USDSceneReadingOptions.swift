public struct USDSceneReadingOptions: Sendable, Equatable, Hashable {
    public var timeCode: Double?

    public init(timeCode: Double? = nil) {
        self.timeCode = timeCode
    }

    public static let `default` = USDSceneReadingOptions()
}
