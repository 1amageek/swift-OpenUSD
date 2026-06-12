public struct SdfTimeSample: Sendable, Equatable, Hashable {
    public var timeCode: Double
    public var value: SdfFieldValue?

    public init(timeCode: Double, value: SdfFieldValue?) {
        self.timeCode = timeCode
        self.value = value
    }
}
