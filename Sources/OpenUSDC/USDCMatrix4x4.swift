import OpenUSD
import Foundation

struct USDCMatrix4x4: Sendable, Equatable {
    var values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    var usdTransformMatrix: USDTransformMatrix4x4 {
        USDTransformMatrix4x4(values: values)
    }

    static var identity: USDCMatrix4x4 {
        USDCMatrix4x4(values: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
    }

    static func translation(_ vector: USDCVector3D) -> USDCMatrix4x4 {
        USDCMatrix4x4(values: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            vector.x, vector.y, vector.z, 1,
        ])
    }

    static func scale(_ vector: USDCVector3D) -> USDCMatrix4x4 {
        USDCMatrix4x4(values: [
            vector.x, 0, 0, 0,
            0, vector.y, 0, 0,
            0, 0, vector.z, 0,
            0, 0, 0, 1,
        ])
    }

    static func rotationX(angleInDegrees angle: Double) throws -> USDCMatrix4x4 {
        let radians = try radians(fromDegrees: angle)
        let sine = sin(radians)
        let cosine = cos(radians)
        return USDCMatrix4x4(values: [
            1, 0, 0, 0,
            0, cosine, sine, 0,
            0, -sine, cosine, 0,
            0, 0, 0, 1,
        ])
    }

    static func rotationY(angleInDegrees angle: Double) throws -> USDCMatrix4x4 {
        let radians = try radians(fromDegrees: angle)
        let sine = sin(radians)
        let cosine = cos(radians)
        return USDCMatrix4x4(values: [
            cosine, 0, -sine, 0,
            0, 1, 0, 0,
            sine, 0, cosine, 0,
            0, 0, 0, 1,
        ])
    }

    static func rotationZ(angleInDegrees angle: Double) throws -> USDCMatrix4x4 {
        let radians = try radians(fromDegrees: angle)
        let sine = sin(radians)
        let cosine = cos(radians)
        return USDCMatrix4x4(values: [
            cosine, sine, 0, 0,
            -sine, cosine, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
    }

    static func eulerRotation(order: String, anglesInDegrees angles: USDCVector3D) throws -> USDCMatrix4x4 {
        var transform = USDCMatrix4x4.identity
        for axis in order {
            let axisTransform: USDCMatrix4x4
            switch axis {
            case "X":
                axisTransform = try rotationX(angleInDegrees: angles.x)
            case "Y":
                axisTransform = try rotationY(angleInDegrees: angles.y)
            case "Z":
                axisTransform = try rotationZ(angleInDegrees: angles.z)
            default:
                throw USDError.invalidData("USDC Euler rotation order is malformed.")
            }
            transform = try transform.concatenating(axisTransform)
        }
        return transform
    }

    func concatenating(_ rhs: USDCMatrix4x4) throws -> USDCMatrix4x4 {
        let lhsValues = try validatedValues(context: "left concatenation")
        let rhsValues = try rhs.validatedValues(context: "right concatenation")
        return USDCMatrix4x4(values: Self.multiplied(lhsValues, rhsValues))
    }

    private static func multiplied(_ lhsValues: [Double], _ rhsValues: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                var value = 0.0
                for index in 0..<4 {
                    value += lhsValues[row * 4 + index] * rhsValues[index * 4 + column]
                }
                output[row * 4 + column] = value
            }
        }
        return output
    }

    func inverted() throws -> USDCMatrix4x4 {
        var matrix = try validatedValues(context: "inverse xform op")
        var inverse = USDCMatrix4x4.identity.values
        var determinant = 1.0
        var swapCount = 0
        for column in 0..<4 {
            var pivotRow = column
            var pivotMagnitude = abs(matrix[column * 4 + column])
            for row in (column + 1)..<4 {
                let magnitude = abs(matrix[row * 4 + column])
                if magnitude > pivotMagnitude {
                    pivotRow = row
                    pivotMagnitude = magnitude
                }
            }
            guard pivotMagnitude.isFinite, pivotMagnitude > Double.leastNormalMagnitude else {
                throw USDError.invalidData("USDC inverse xform op is singular.")
            }
            if pivotRow != column {
                swapRows(column, pivotRow, in: &matrix)
                swapRows(column, pivotRow, in: &inverse)
                swapCount += 1
            }
            let pivot = matrix[column * 4 + column]
            determinant *= pivot
            for index in 0..<4 {
                matrix[column * 4 + index] /= pivot
                inverse[column * 4 + index] /= pivot
            }
            for row in 0..<4 where row != column {
                let factor = matrix[row * 4 + column]
                if factor == 0 {
                    continue
                }
                for index in 0..<4 {
                    matrix[row * 4 + index] -= factor * matrix[column * 4 + index]
                    inverse[row * 4 + index] -= factor * inverse[column * 4 + index]
                }
            }
        }
        if swapCount % 2 == 1 {
            determinant = -determinant
        }
        guard determinant.isFinite, abs(determinant) > 1.0e-9 else {
            throw USDError.invalidData("USDC inverse xform op is singular.")
        }
        guard inverse.allSatisfy(\.isFinite) else {
            throw USDError.invalidData("USDC inverse xform op produced a non-finite matrix.")
        }
        return USDCMatrix4x4(values: inverse)
    }

    func transform(_ point: USDPoint3D) throws -> USDPoint3D {
        let values = try validatedValues(context: "transform")
        let x = point.x * values[0] + point.y * values[4] + point.z * values[8] + values[12]
        let y = point.x * values[1] + point.y * values[5] + point.z * values[9] + values[13]
        let z = point.x * values[2] + point.y * values[6] + point.z * values[10] + values[14]
        let w = point.x * values[3] + point.y * values[7] + point.z * values[11] + values[15]
        guard x.isFinite, y.isFinite, z.isFinite, w.isFinite else {
            throw USDError.invalidData("USDC transform produced a non-finite point.")
        }
        guard w != 0 else {
            throw USDError.invalidData("USDC transform produced a point with zero homogeneous weight.")
        }
        return USDPoint3D(x: x / w, y: y / w, z: z / w)
    }

    func transform(normal: USDPoint3D) throws -> USDPoint3D {
        let values = try validatedValues(context: "normal transform")
        guard values[3] == 0, values[7] == 0, values[11] == 0 else {
            throw USDError.unsupportedFeature("USDC normal transforms require affine matrices.")
        }
        let m00 = values[0]
        let m01 = values[1]
        let m02 = values[2]
        let m10 = values[4]
        let m11 = values[5]
        let m12 = values[6]
        let m20 = values[8]
        let m21 = values[9]
        let m22 = values[10]
        let determinant =
            m00 * (m11 * m22 - m12 * m21) -
            m01 * (m10 * m22 - m12 * m20) +
            m02 * (m10 * m21 - m11 * m20)
        guard determinant.isFinite, determinant != 0 else {
            throw USDError.invalidData("USDC normal transform is singular.")
        }

        let inverse00 = (m11 * m22 - m12 * m21) / determinant
        let inverse01 = (m02 * m21 - m01 * m22) / determinant
        let inverse02 = (m01 * m12 - m02 * m11) / determinant
        let inverse10 = (m12 * m20 - m10 * m22) / determinant
        let inverse11 = (m00 * m22 - m02 * m20) / determinant
        let inverse12 = (m02 * m10 - m00 * m12) / determinant
        let inverse20 = (m10 * m21 - m11 * m20) / determinant
        let inverse21 = (m01 * m20 - m00 * m21) / determinant
        let inverse22 = (m00 * m11 - m01 * m10) / determinant

        let x = inverse00 * normal.x + inverse01 * normal.y + inverse02 * normal.z
        let y = inverse10 * normal.x + inverse11 * normal.y + inverse12 * normal.z
        let z = inverse20 * normal.x + inverse21 * normal.y + inverse22 * normal.z
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw USDError.invalidData("USDC transform produced a non-finite normal.")
        }
        let length = sqrt(x * x + y * y + z * z)
        guard length.isFinite, length > 0 else {
            throw USDError.invalidData("USDC transform produced a zero-length normal.")
        }
        return USDPoint3D(x: x / length, y: y / length, z: z / length)
    }

    private static func radians(fromDegrees angle: Double) throws -> Double {
        guard angle.isFinite else {
            throw USDError.invalidData("USDC rotation angle is not finite.")
        }
        return angle * .pi / 180
    }

    private func validatedValues(context: String) throws -> [Double] {
        guard values.count == 16 else {
            throw USDError.invalidData("USDC \(context) matrix must contain exactly 16 values.")
        }
        return values
    }

    private func swapRows(_ lhs: Int, _ rhs: Int, in values: inout [Double]) {
        for column in 0..<4 {
            values.swapAt(lhs * 4 + column, rhs * 4 + column)
        }
    }
}
