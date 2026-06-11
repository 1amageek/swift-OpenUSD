public struct USDTextureCoordinatePrimvar: Sendable, Hashable {
    public var values: [USDPoint2D]
    public var indices: [Int]?
    public var interpolation: String?

    public init(
        values: [USDPoint2D] = [],
        indices: [Int]? = nil,
        interpolation: String? = nil
    ) {
        self.values = values
        self.indices = indices
        self.interpolation = interpolation
    }

    public func validate(pointCount: Int, faceVertexCounts: [Int]) throws {
        guard !values.isEmpty else {
            throw USDError.invalidData("USD primvars:st contains no texture coordinate values.")
        }
        for value in values {
            guard value.x.isFinite, value.y.isFinite else {
                throw USDError.invalidData("USD primvars:st contains a non-finite texture coordinate.")
            }
        }
        try validateUSDPrimvarIndices(indices, valueCount: values.count, name: "primvars:st")
        try validateUSDPrimvarElementCount(
            indices?.count ?? values.count,
            interpolation: interpolation,
            pointCount: pointCount,
            faceVertexCounts: faceVertexCounts,
            name: "primvars:st"
        )
    }
}
