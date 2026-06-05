public struct USDSceneReadingOptions: Sendable, Equatable, Hashable {
    public var timeCode: Double?
    public var timeSampleInterpolation: USDTimeSampleInterpolation

    public init(
        timeCode: Double? = nil,
        timeSampleInterpolation: USDTimeSampleInterpolation = .linear
    ) {
        self.timeCode = timeCode
        self.timeSampleInterpolation = timeSampleInterpolation
    }

    public static let `default` = USDSceneReadingOptions()
}
