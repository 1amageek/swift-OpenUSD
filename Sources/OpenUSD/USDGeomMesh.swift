import Foundation

public struct USDGeomMesh: Sendable, Equatable, Hashable {
    public var prim: USDPrim

    public init(prim: USDPrim) {
        self.prim = prim
    }

    @discardableResult
    public static func define(in stage: inout USDStage, at path: SdfPath) throws -> USDGeomMesh {
        let prim = try stage.definePrim(at: path, typeName: "Mesh")
        return USDGeomMesh(prim: prim)
    }

    public func setTopology(
        points: [USDPoint3D],
        faceVertexCounts: [Int],
        faceVertexIndices: [Int],
        in stage: inout USDStage
    ) throws {
        try USDMesh.validateTopology(
            pointCount: points.count,
            faceVertexCounts: faceVertexCounts,
            faceVertexIndices: faceVertexIndices
        )
        try setPoints(points, in: &stage)
        try setFaceVertexCounts(faceVertexCounts, in: &stage)
        try setFaceVertexIndices(faceVertexIndices, in: &stage)
    }

    public func setPoints(_ points: [USDPoint3D], in stage: inout USDStage) throws {
        try validateFinite(points)
        try validateAuthoredTopology(points: points, stage: stage)
        _ = try stage.createAttribute(
            at: prim.path,
            name: "points",
            typeName: "point3f[]",
            defaultValue: point3Array(points)
        )
    }

    public func setFaceVertexCounts(_ values: [Int], in stage: inout USDStage) throws {
        try validateAuthoredTopology(faceVertexCounts: values, stage: stage)
        _ = try stage.createAttribute(
            at: prim.path,
            name: "faceVertexCounts",
            typeName: "int[]",
            defaultValue: intArray(values)
        )
    }

    public func setFaceVertexIndices(_ values: [Int], in stage: inout USDStage) throws {
        try validateAuthoredTopology(faceVertexIndices: values, stage: stage)
        _ = try stage.createAttribute(
            at: prim.path,
            name: "faceVertexIndices",
            typeName: "int[]",
            defaultValue: intArray(values)
        )
    }

    public func setSubdivisionScheme(_ value: String, in stage: inout USDStage) throws {
        _ = try stage.createAttribute(
            at: prim.path,
            name: "subdivisionScheme",
            typeName: "token",
            defaultValue: "\"\(escaped(value))\"",
            variability: .uniform
        )
    }

    public func setOrientation(_ value: USDOrientation, in stage: inout USDStage) throws {
        _ = try stage.createAttribute(
            at: prim.path,
            name: "orientation",
            typeName: "token",
            defaultValue: "\"\(value.rawValue)\"",
            variability: .uniform
        )
    }

    private func intArray(_ values: [Int]) -> String {
        "[\(values.map(String.init).joined(separator: ", "))]"
    }

    private func point3Array(_ values: [USDPoint3D]) -> String {
        "[\(values.map { "(\(formatDouble($0.x)), \(formatDouble($0.y)), \(formatDouble($0.z)))" }.joined(separator: ", "))]"
    }

    private func formatDouble(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    private func validateFinite(_ points: [USDPoint3D]) throws {
        for point in points {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                throw USDError.invalidData("UsdGeomMesh points must be finite.")
            }
        }
    }

    private func validateAuthoredTopology(
        points: [USDPoint3D]? = nil,
        faceVertexCounts: [Int]? = nil,
        faceVertexIndices: [Int]? = nil,
        stage: USDStage
    ) throws {
        let authoredPoints = points ?? authoredPointArray(named: "points", in: stage)
        let authoredCounts = faceVertexCounts ?? authoredIntArray(named: "faceVertexCounts", in: stage)
        let authoredIndices = faceVertexIndices ?? authoredIntArray(named: "faceVertexIndices", in: stage)
        guard let authoredPoints, let authoredCounts, let authoredIndices else {
            return
        }
        try USDMesh.validateTopology(
            pointCount: authoredPoints.count,
            faceVertexCounts: authoredCounts,
            faceVertexIndices: authoredIndices
        )
    }

    private func authoredIntArray(named name: String, in stage: USDStage) -> [Int]? {
        guard let value = authoredDefaultValue(named: name, in: stage) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return nil
        }
        let body = trimmed.dropFirst().dropLast()
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        var values: [Int] = []
        for component in body.split(separator: ",") {
            guard let value = Int(component.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    private func authoredPointArray(named name: String, in stage: USDStage) -> [USDPoint3D]? {
        guard let value = authoredDefaultValue(named: name, in: stage) else {
            return nil
        }
        let pattern = #"\(([^()]*)\)"#
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var points: [USDPoint3D] = []
        for match in expression.matches(in: value, range: range) {
            guard let componentRange = Range(match.range(at: 1), in: value) else {
                return nil
            }
            let components = value[componentRange].split(separator: ",")
            guard components.count == 3,
                  let x = Double(components[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(components[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let z = Double(components[2].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            points.append(USDPoint3D(x: x, y: y, z: z))
        }
        return points
    }

    private func authoredDefaultValue(named name: String, in stage: USDStage) -> String? {
        guard let spec = stage.rootLayer.spec(at: "\(prim.path.rawValue).\(name)"),
              case .authored(let value)? = spec.fields["default"] else {
            return nil
        }
        return value
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
