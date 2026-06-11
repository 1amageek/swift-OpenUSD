import Foundation

public struct USDGeomXform: Sendable, Equatable, Hashable {
    public var prim: USDPrim

    public init(prim: USDPrim) {
        self.prim = prim
    }

    @discardableResult
    public static func define(in stage: inout USDStage, at path: SdfPath) throws -> USDGeomXform {
        let prim = try stage.definePrim(at: path, typeName: "Xform")
        return USDGeomXform(prim: prim)
    }

    public func setTranslate(_ value: USDTransformVector3D, in stage: inout USDStage) throws {
        let operationName = "xformOp:translate"
        _ = try stage.createAttribute(
            at: prim.path,
            name: operationName,
            typeName: "double3",
            defaultValue: "(\(formatDouble(value.x)), \(formatDouble(value.y)), \(formatDouble(value.z)))"
        )
        var order = xformOpOrder(in: stage)
        if !order.contains(operationName) {
            order.append(operationName)
        }
        _ = try stage.createAttribute(
            at: prim.path,
            name: "xformOpOrder",
            typeName: "token[]",
            defaultValue: tokenArray(order),
            variability: .uniform
        )
    }

    private func xformOpOrder(in stage: USDStage) -> [String] {
        guard let spec = stage.rootLayer.spec(at: "\(prim.path.rawValue).xformOpOrder"),
              case .authored(let value)? = spec.fields["default"] else {
            return []
        }
        return parseTokenArray(value)
    }

    private func parseTokenArray(_ value: String) -> [String] {
        var tokens: [String] = []
        var cursor = value.startIndex
        while cursor < value.endIndex {
            guard value[cursor] == "\"" else {
                cursor = value.index(after: cursor)
                continue
            }
            cursor = value.index(after: cursor)
            var token = ""
            var isEscaped = false
            while cursor < value.endIndex {
                let character = value[cursor]
                if isEscaped {
                    token.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    tokens.append(token)
                    break
                } else {
                    token.append(character)
                }
                cursor = value.index(after: cursor)
            }
            if cursor < value.endIndex {
                cursor = value.index(after: cursor)
            }
        }
        return tokens
    }

    private func tokenArray(_ values: [String]) -> String {
        "[\(values.map { "\"\(escaped($0))\"" }.joined(separator: ", "))]"
    }

    private func formatDouble(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
