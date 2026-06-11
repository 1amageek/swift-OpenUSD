public struct USDMesh: Sendable, Hashable {
    public static let fallbackSubdivisionScheme = "catmullClark"

    public var name: String?
    public var primPath: String?
    public var points: [USDPoint3D]
    public var faceVertexCounts: [Int]
    public var faceVertexIndices: [Int]
    public var normals: [USDPoint3D]
    public var normalsInterpolation: String?
    public var orientation: USDOrientation?
    public var subdivisionScheme: String?
    public var textureCoordinates: USDTextureCoordinatePrimvar?
    public var displayColor: USDDisplayColorPrimvar?
    public var displayOpacity: USDDisplayOpacityPrimvar?
    public var extent: [USDPoint3D]?

    public init(
        name: String? = nil,
        primPath: String? = nil,
        points: [USDPoint3D] = [],
        faceVertexCounts: [Int] = [],
        faceVertexIndices: [Int] = [],
        normals: [USDPoint3D] = [],
        normalsInterpolation: String? = nil,
        orientation: USDOrientation? = nil,
        subdivisionScheme: String? = nil,
        textureCoordinates: USDTextureCoordinatePrimvar? = nil,
        displayColor: USDDisplayColorPrimvar? = nil,
        displayOpacity: USDDisplayOpacityPrimvar? = nil,
        extent: [USDPoint3D]? = nil
    ) {
        self.name = name
        self.primPath = primPath
        self.points = points
        self.faceVertexCounts = faceVertexCounts
        self.faceVertexIndices = faceVertexIndices
        self.normals = normals
        self.normalsInterpolation = normalsInterpolation
        self.orientation = orientation
        self.subdivisionScheme = subdivisionScheme
        self.textureCoordinates = textureCoordinates
        self.displayColor = displayColor
        self.displayOpacity = displayOpacity
        self.extent = extent
    }

    public var effectiveSubdivisionScheme: String {
        subdivisionScheme ?? Self.fallbackSubdivisionScheme
    }

    public static func validateTopology(
        pointCount: Int,
        faceVertexCounts: [Int],
        faceVertexIndices: [Int]
    ) throws {
        guard pointCount > 0 else {
            throw USDError.invalidData("USD Mesh topology requires at least one point.")
        }
        guard !faceVertexCounts.isEmpty else {
            throw USDError.invalidData("USD Mesh faceVertexCounts is empty.")
        }
        var expectedIndexCount = 0
        for count in faceVertexCounts {
            guard count > 0 else {
                throw USDError.invalidData("USD Mesh faceVertexCounts contains a non-positive face size.")
            }
            let result = expectedIndexCount.addingReportingOverflow(count)
            guard !result.overflow else {
                throw USDError.invalidData("USD Mesh faceVertexCounts exceeds platform range.")
            }
            expectedIndexCount = result.partialValue
        }
        guard expectedIndexCount == faceVertexIndices.count else {
            throw USDError.invalidData("USD Mesh faceVertexCounts does not match faceVertexIndices count.")
        }
        for index in faceVertexIndices {
            guard index >= 0, index < pointCount else {
                throw USDError.invalidData("USD Mesh faceVertexIndices contains an index outside points.")
            }
        }
    }
}
