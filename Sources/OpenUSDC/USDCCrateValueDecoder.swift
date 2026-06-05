import OpenUSD
import Foundation

private struct USDCTimeSampleValueRep {
    var timeCode: Double
    var valueRep: USDCCrateValueRep?
}

struct USDCCrateValueDecoder {
    private let crate: USDCCrateFile
    private let tokens: [String]
    private let strings: [String]

    init(crate: USDCCrateFile, tokens: [String], strings: [String]) {
        self.crate = crate
        self.tokens = tokens
        self.strings = strings
    }

    func readStringLike(_ valueRep: USDCCrateValueRep) throws -> String {
        let value = try readValue(valueRep)
        guard let string = value.stringValue else {
            throw USDImportError.invalidData("USDC value is not a string-like value.")
        }
        return string
    }

    func readDouble(_ valueRep: USDCCrateValueRep) throws -> Double {
        let value = try readValue(valueRep)
        guard let double = value.doubleValue else {
            throw USDImportError.invalidData("USDC value is not a double value.")
        }
        return double
    }

    func readDoubleArray(_ valueRep: USDCCrateValueRep) throws -> [Double] {
        let value = try readValue(valueRep)
        guard let array = value.doubleArrayValue else {
            throw USDImportError.invalidData("USDC value is not a double array.")
        }
        return array
    }

    func readTokenArray(_ valueRep: USDCCrateValueRep) throws -> [String] {
        let value = try readValue(valueRep)
        guard let array = value.tokenArrayValue else {
            throw USDImportError.invalidData("USDC value is not a token array.")
        }
        return array
    }

    func readLayerFieldValue(_ valueRep: USDCCrateValueRep) throws -> USDCLayerFieldValue? {
        guard let type = valueRep.type else {
            throw USDImportError.invalidData("USDC value has an unknown value type.")
        }
        switch type {
        case .bool:
            if valueRep.isArray {
                return .boolArray(try readBoolArrayValue(valueRep))
            }
            return .bool(try readBoolScalar(valueRep))
        case .uChar:
            if valueRep.isArray {
                return .intArray(try readUInt8ArrayValue(valueRep))
            }
            return .int(try readUInt8Scalar(valueRep))
        case .uInt:
            if valueRep.isArray {
                return .intArray(try readUInt32ArrayValue(valueRep))
            }
            return .int(try readUInt32Scalar(valueRep))
        case .int64:
            if valueRep.isArray {
                return .intArray(try readInt64ArrayValue(valueRep))
            }
            return .int(try readInt64Scalar(valueRep))
        case .uInt64:
            if valueRep.isArray {
                return .intArray(try readUInt64ArrayValue(valueRep))
            }
            return .int(try readUInt64Scalar(valueRep))
        case .token:
            if valueRep.isArray {
                return .tokenArray(try readTokenArrayValue(valueRep))
            }
            return .token(try readToken(valueRep))
        case .tokenVector:
            return .tokenVector(try readTokenVectorValue(valueRep))
        case .string:
            return .string(try readString(valueRep))
        case .assetPath:
            return .assetPath(try readAssetPath(valueRep))
        case .dictionary:
            return .dictionary(try readDictionaryValue(valueRep))
        case .pathVector:
            return .pathVector(try readPathVectorValue(valueRep))
        case .tokenListOperation:
            return .tokenListOperation(try readTokenListOperation(valueRep))
        case .stringListOperation:
            return .stringListOperation(try readStringListOperation(valueRep))
        case .pathListOperation:
            return .pathListOperation(try readPathListOperation(valueRep))
        case .referenceListOperation:
            return .referenceListOperation(try readReferenceListOperation(valueRep))
        case .payloadListOperation:
            return .payloadListOperation(try readPayloadListOperation(valueRep))
        case .payload:
            return .payload(try readPayloadValue(valueRep))
        case .float:
            if valueRep.isArray {
                return .doubleArray(try readFloatArrayValue(valueRep))
            }
            return .double(Double(try readFloatScalar(valueRep)))
        case .double:
            if valueRep.isArray {
                return .doubleArray(try readDoubleArrayValue(valueRep))
            }
            return .double(try readDoubleScalar(valueRep))
        case .int:
            if valueRep.isArray {
                return .intArray(try readIntArrayValue(valueRep))
            }
            return .int(try readIntScalar(valueRep))
        case .vec2d:
            if valueRep.isArray {
                return .point2Array(try readVec2dArrayValue(valueRep))
            }
            return .point2(try readVec2dScalar(valueRep))
        case .vec2f:
            if valueRep.isArray {
                return .point2Array(try readVec2fArrayValue(valueRep))
            }
            return .point2(try readVec2fScalar(valueRep))
        case .specifier:
            guard valueRep.isInlined, !valueRep.isArray else {
                throw USDImportError.invalidData("USDC specifier field is malformed.")
            }
            return .specifier(USDCPrimSpecifier(payload: valueRep.payload))
        default:
            return nil
        }
    }

    func readVector3(_ valueRep: USDCCrateValueRep) throws -> USDCVector3D {
        let value = try readValue(valueRep)
        guard let vector = value.vector3Value else {
            throw USDImportError.invalidData("USDC value is not a vector3 value.")
        }
        return vector
    }

    func readQuaternion(_ valueRep: USDCCrateValueRep) throws -> USDCQuaternion {
        let value = try readValue(valueRep)
        guard let quaternion = value.quaternionValue else {
            throw USDImportError.invalidData("USDC value is not a quaternion value.")
        }
        return quaternion
    }

    func readMatrix4x4(_ valueRep: USDCCrateValueRep) throws -> USDCMatrix4x4 {
        let value = try readValue(valueRep)
        guard let matrix = value.matrix4x4Value else {
            throw USDImportError.invalidData("USDC value is not a matrix4d value.")
        }
        return matrix
    }

    func readFirstUnblockedTimeSampleValueRep(_ valueRep: USDCCrateValueRep) throws -> USDCCrateValueRep? {
        try readTimeSampleValueRep(valueRep, at: nil)
    }

    func readTimeSampleValueRep(_ valueRep: USDCCrateValueRep, at timeCode: Double?) throws -> USDCCrateValueRep? {
        let samples = try readTimeSampleValueReps(valueRep, at: timeCode)
        guard let timeCode else {
            return samples.first { $0.valueRep != nil }?.valueRep
        }
        var lowerSample: USDCTimeSampleValueRep?
        var upperSample: USDCTimeSampleValueRep?
        for sample in samples {
            if sample.timeCode == timeCode {
                return sample.valueRep
            }
            guard sample.valueRep != nil else {
                continue
            }
            if sample.timeCode < timeCode {
                lowerSample = sample
            } else if sample.timeCode > timeCode {
                upperSample = sample
                break
            }
        }
        return lowerSample?.valueRep ?? upperSample?.valueRep
    }

    func readPointTimeSampleArray(
        _ valueRep: USDCCrateValueRep,
        at timeCode: Double?,
        interpolation: USDTimeSampleInterpolation
    ) throws -> [USDPoint3D]? {
        let samples = try readTimeSampleValueReps(valueRep, at: timeCode)
        guard let timeCode else {
            guard let firstSample = samples.first(where: { $0.valueRep != nil })?.valueRep else {
                return nil
            }
            return try readPointArray(firstSample)
        }
        var lowerSample: USDCTimeSampleValueRep?
        var upperSample: USDCTimeSampleValueRep?
        for sample in samples {
            if sample.timeCode == timeCode {
                return try sample.valueRep.map { try readPointArray($0) }
            }
            guard sample.valueRep != nil else {
                continue
            }
            if sample.timeCode < timeCode {
                lowerSample = sample
            } else if sample.timeCode > timeCode {
                upperSample = sample
                break
            }
        }
        switch interpolation {
        case .held:
            guard let sampleRep = lowerSample?.valueRep ?? upperSample?.valueRep else {
                return nil
            }
            return try readPointArray(sampleRep)
        case .linear:
            guard let lowerSample, let lowerRep = lowerSample.valueRep else {
                guard let upperRep = upperSample?.valueRep else {
                    return nil
                }
                return try readPointArray(upperRep)
            }
            guard let upperSample, let upperRep = upperSample.valueRep else {
                return try readPointArray(lowerRep)
            }
            let lowerPoints = try readPointArray(lowerRep)
            let upperPoints = try readPointArray(upperRep)
            guard upperSample.timeCode > lowerSample.timeCode,
                  lowerPoints.count == upperPoints.count else {
                return lowerPoints
            }
            let fraction = (timeCode - lowerSample.timeCode) / (upperSample.timeCode - lowerSample.timeCode)
            guard fraction.isFinite else {
                return lowerPoints
            }
            return zip(lowerPoints, upperPoints).map { lower, upper in
                USDPoint3D(
                    x: lower.x + (upper.x - lower.x) * fraction,
                    y: lower.y + (upper.y - lower.y) * fraction,
                    z: lower.z + (upper.z - lower.z) * fraction
                )
            }
        }
    }

    private func readTimeSampleValueReps(
        _ valueRep: USDCCrateValueRep,
        at timeCode: Double?
    ) throws -> [USDCTimeSampleValueRep] {
        guard valueRep.type == .timeSamples, !valueRep.isArray, !valueRep.isInlined else {
            throw USDImportError.invalidData("USDC timeSamples field is malformed.")
        }
        if let timeCode, !timeCode.isFinite {
            throw USDImportError.invalidData("USDC timeSamples requested timeCode must be finite.")
        }
        var cursor = try payloadOffset(valueRep, label: "timeSamples")
        cursor = try recursivePayloadEnd(start: cursor, label: "USDC timeSamples times")
        let timesRep = USDCCrateValueRep(rawValue: try crate.readFileUInt64(at: cursor))
        cursor += MemoryLayout<UInt64>.size
        cursor = try recursivePayloadEnd(start: cursor, label: "USDC timeSamples values")
        let valueCount = try checkedInt(
            try crate.readFileUInt64(at: cursor),
            label: "USDC timeSamples value count"
        )
        cursor += MemoryLayout<UInt64>.size
        guard valueCount > 0 else {
            throw USDImportError.invalidData("USDC timeSamples contains no values.")
        }
        let times = try readDoubleVectorValues(timesRep)
        guard times.count == valueCount else {
            throw USDImportError.invalidData("USDC timeSamples times and values have different counts.")
        }
        var samples: [USDCTimeSampleValueRep] = []
        samples.reserveCapacity(valueCount)
        for index in 0..<valueCount {
            let sampleCursor = cursor + index * MemoryLayout<UInt64>.size
            let sampleRep = USDCCrateValueRep(rawValue: try crate.readFileUInt64(at: sampleCursor))
            samples.append(USDCTimeSampleValueRep(
                timeCode: times[index],
                valueRep: isBlockedValue(sampleRep) ? nil : sampleRep
            ))
        }
        samples.sort { lhs, rhs in
            lhs.timeCode < rhs.timeCode
        }
        return samples
    }

    func isBlockedValue(_ valueRep: USDCCrateValueRep) -> Bool {
        isValueBlock(valueRep) || isAnimationBlock(valueRep)
    }

    func isValueBlock(_ valueRep: USDCCrateValueRep) -> Bool {
        valueRep.type == .valueBlock
    }

    func isAnimationBlock(_ valueRep: USDCCrateValueRep) -> Bool {
        valueRep.type == .animationBlock
    }

    func readIntArray(_ valueRep: USDCCrateValueRep) throws -> [Int] {
        let value = try readValue(valueRep)
        guard let array = value.intArrayValue else {
            throw USDImportError.invalidData("USDC value is not an int array.")
        }
        return array
    }

    func readPointArray(_ valueRep: USDCCrateValueRep) throws -> [USDPoint3D] {
        let value = try readValue(valueRep)
        guard let array = value.pointArrayValue else {
            throw USDImportError.invalidData("USDC value is not a point array.")
        }
        return array
    }

    func readPoint2Array(_ valueRep: USDCCrateValueRep) throws -> [USDPoint2D] {
        let value = try readValue(valueRep)
        guard let array = value.point2ArrayValue else {
            throw USDImportError.invalidData("USDC value is not a point2 array.")
        }
        return array
    }

    private func readValue(_ valueRep: USDCCrateValueRep) throws -> USDCCrateValue {
        guard let type = valueRep.type else {
            throw USDImportError.invalidData("USDC value has an unknown value type.")
        }
        switch type {
        case .bool:
            if valueRep.isArray {
                return .boolArray(try readBoolArrayValue(valueRep))
            }
            return .bool(try readBoolScalar(valueRep))
        case .uChar:
            if valueRep.isArray {
                return .intArray(try readUInt8ArrayValue(valueRep))
            }
            return .int(try readUInt8Scalar(valueRep))
        case .uInt:
            if valueRep.isArray {
                return .intArray(try readUInt32ArrayValue(valueRep))
            }
            return .int(try readUInt32Scalar(valueRep))
        case .int64:
            if valueRep.isArray {
                return .intArray(try readInt64ArrayValue(valueRep))
            }
            return .int(try readInt64Scalar(valueRep))
        case .uInt64:
            if valueRep.isArray {
                return .intArray(try readUInt64ArrayValue(valueRep))
            }
            return .int(try readUInt64Scalar(valueRep))
        case .token:
            if valueRep.isArray {
                return .tokenArray(try readTokenArrayValue(valueRep))
            }
            return .token(try readToken(valueRep))
        case .tokenVector:
            return .tokenVector(try readTokenVectorValue(valueRep))
        case .string:
            return .string(try readString(valueRep))
        case .assetPath:
            return .assetPath(try readAssetPath(valueRep))
        case .dictionary:
            return .dictionary(try readDictionaryValue(valueRep))
        case .pathVector:
            return .pathVector(try readPathVectorValue(valueRep))
        case .tokenListOperation:
            return .tokenListOperation(try readTokenListOperation(valueRep))
        case .stringListOperation:
            return .stringListOperation(try readStringListOperation(valueRep))
        case .pathListOperation:
            return .pathListOperation(try readPathListOperation(valueRep))
        case .referenceListOperation:
            return .referenceListOperation(try readReferenceListOperation(valueRep))
        case .payloadListOperation:
            return .payloadListOperation(try readPayloadListOperation(valueRep))
        case .payload:
            return .payload(try readPayloadValue(valueRep))
        case .float:
            if valueRep.isArray {
                return .doubleArray(try readFloatArrayValue(valueRep))
            }
            return .double(Double(try readFloatScalar(valueRep)))
        case .double:
            if valueRep.isArray {
                return .doubleArray(try readDoubleArrayValue(valueRep))
            }
            return .double(try readDoubleScalar(valueRep))
        case .int:
            if valueRep.isArray {
                return .intArray(try readIntArrayValue(valueRep))
            }
            return .int(try readIntScalar(valueRep))
        case .quatd:
            guard !valueRep.isArray else {
                throw USDImportError.unsupportedFeature("USDC quatd arrays are not materialized yet.")
            }
            return .quaternion(try readQuatdScalar(valueRep))
        case .quatf:
            guard !valueRep.isArray else {
                throw USDImportError.unsupportedFeature("USDC quatf arrays are not materialized yet.")
            }
            return .quaternion(try readQuatfScalar(valueRep))
        case .quath:
            throw USDImportError.unsupportedFeature("USDC quath values are not materialized yet.")
        case .vec3d:
            if valueRep.isArray {
                return .pointArray(try readVec3dArrayValue(valueRep))
            }
            return .vector3(try readVec3dScalar(valueRep))
        case .vec3f:
            if valueRep.isArray {
                return .pointArray(try readVec3fArrayValue(valueRep))
            }
            return .vector3(try readVec3fScalar(valueRep))
        case .vec2d:
            if valueRep.isArray {
                return .point2Array(try readVec2dArrayValue(valueRep))
            }
            return .point2(try readVec2dScalar(valueRep))
        case .vec2f:
            if valueRep.isArray {
                return .point2Array(try readVec2fArrayValue(valueRep))
            }
            return .point2(try readVec2fScalar(valueRep))
        case .matrix4d:
            guard !valueRep.isArray else {
                throw USDImportError.unsupportedFeature("USDC matrix4d arrays are not materialized yet.")
            }
            return .matrix4x4(try readMatrix4dScalar(valueRep))
        default:
            throw USDImportError.unsupportedFeature("USDC value type \(type) is not materialized yet.")
        }
    }

    private func readToken(_ valueRep: USDCCrateValueRep) throws -> String {
        let tokenIndex = try readIndexPayload(valueRep, sectionName: "TOKENS")
        guard tokenIndex < tokens.count else {
            throw USDImportError.invalidData("USDC token value references a token outside TOKENS.")
        }
        return tokens[tokenIndex]
    }

    private func readString(_ valueRep: USDCCrateValueRep) throws -> String {
        let stringIndex = try readIndexPayload(valueRep, sectionName: "STRINGS")
        guard stringIndex < strings.count else {
            throw USDImportError.invalidData("USDC string value references a string outside STRINGS.")
        }
        return strings[stringIndex]
    }

    private func readAssetPath(_ valueRep: USDCCrateValueRep) throws -> String {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC assetPath value is marked as an array.")
        }
        if valueRep.isInlined {
            let tokenIndex = try checkedInt(
                valueRep.payload & UInt64(UInt32.max),
                label: "USDC assetPath token index"
            )
            guard tokenIndex < tokens.count else {
                throw USDImportError.invalidData("USDC assetPath value references a token outside TOKENS.")
            }
            return tokens[tokenIndex]
        }
        let stringIndex = try readIndexPayload(valueRep, sectionName: "STRINGS")
        guard stringIndex < strings.count else {
            throw USDImportError.invalidData("USDC assetPath value references a string outside STRINGS.")
        }
        return strings[stringIndex]
    }

    private func readIndexPayload(_ valueRep: USDCCrateValueRep, sectionName: String) throws -> Int {
        let rawIndex: UInt32
        if valueRep.isInlined {
            rawIndex = UInt32(valueRep.payload & UInt64(UInt32.max))
        } else {
            rawIndex = try crate.readFileUInt32(at: try payloadOffset(valueRep, label: sectionName))
        }
        guard let index = Int(exactly: rawIndex) else {
            throw USDImportError.invalidData("USDC \(sectionName) value index exceeds platform range.")
        }
        return index
    }

    private func readBoolScalar(_ valueRep: USDCCrateValueRep) throws -> Bool {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC bool value is marked as an array.")
        }
        if valueRep.isInlined {
            return valueRep.payload & 1 != 0
        }
        let bytes = try crate.readFileBytes(
            at: try payloadOffset(valueRep, label: "bool"),
            byteCount: MemoryLayout<UInt8>.size
        )
        return bytes[0] != 0
    }

    private func readUInt8Scalar(_ valueRep: USDCCrateValueRep) throws -> Int {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC uchar value is marked as an array.")
        }
        if valueRep.isInlined {
            return Int(valueRep.payload & UInt64(UInt8.max))
        }
        let bytes = try crate.readFileBytes(
            at: try payloadOffset(valueRep, label: "uchar"),
            byteCount: MemoryLayout<UInt8>.size
        )
        return Int(bytes[0])
    }

    private func readUInt32Scalar(_ valueRep: USDCCrateValueRep) throws -> Int {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC uint value is marked as an array.")
        }
        let value: UInt32
        if valueRep.isInlined {
            value = UInt32(valueRep.payload & UInt64(UInt32.max))
        } else {
            value = try crate.readFileUInt32(at: try payloadOffset(valueRep, label: "uint"))
        }
        return try intValue(UInt64(value), label: "USDC uint value")
    }

    private func readInt64Scalar(_ valueRep: USDCCrateValueRep) throws -> Int {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC int64 value is marked as an array.")
        }
        guard !valueRep.isInlined else {
            throw USDImportError.invalidData("USDC int64 value is unexpectedly inlined.")
        }
        let rawValue = try crate.readFileUInt64(at: try payloadOffset(valueRep, label: "int64"))
        return try intValue(Int64(bitPattern: rawValue), label: "USDC int64 value")
    }

    private func readUInt64Scalar(_ valueRep: USDCCrateValueRep) throws -> Int {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC uint64 value is marked as an array.")
        }
        guard !valueRep.isInlined else {
            throw USDImportError.invalidData("USDC uint64 value is unexpectedly inlined.")
        }
        let value = try crate.readFileUInt64(at: try payloadOffset(valueRep, label: "uint64"))
        return try intValue(value, label: "USDC uint64 value")
    }

    private func readTokenArrayValue(_ valueRep: USDCCrateValueRep) throws -> [String] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC token array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "token array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC token array count")
        let byteCount = try checkedMultiplication(count, MemoryLayout<UInt32>.size, label: "USDC token array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "token array"
        )
        var values: [String] = []
        values.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let tokenIndex = littleEndianUInt32(bytes[byteCursor..<(byteCursor + 4)])
            byteCursor += MemoryLayout<UInt32>.size
            guard tokenIndex < UInt32(tokens.count) else {
                throw USDImportError.invalidData("USDC token array references a token outside TOKENS.")
            }
            values.append(tokens[Int(tokenIndex)])
        }
        return values
    }

    private func readTokenVectorValue(_ valueRep: USDCCrateValueRep) throws -> [String] {
        guard valueRep.type == .tokenVector, !valueRep.isArray else {
            throw USDImportError.invalidData("USDC token vector value is malformed.")
        }
        guard !valueRep.isInlined, !valueRep.isCompressed else {
            throw USDImportError.invalidData("USDC token vector value has unsupported representation bits.")
        }
        guard valueRep.payload != 0 else {
            throw USDImportError.invalidData("USDC token vector payload offset is missing.")
        }
        var cursor = try payloadOffset(valueRep, label: "token vector")
        let count = try checkedInt(try crate.readFileUInt64(at: cursor), label: "USDC token vector count")
        cursor += MemoryLayout<UInt64>.size
        var values: [String] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            let tokenIndex = try checkedInt(
                UInt64(try crate.readFileUInt32(at: cursor)),
                label: "USDC token vector token index"
            )
            cursor += MemoryLayout<UInt32>.size
            guard tokenIndex < tokens.count else {
                throw USDImportError.invalidData("USDC token vector references a token outside TOKENS.")
            }
            values.append(tokens[tokenIndex])
        }
        return values
    }

    private func readPathVectorValue(_ valueRep: USDCCrateValueRep) throws -> [String] {
        guard valueRep.type == .pathVector, !valueRep.isArray else {
            throw USDImportError.invalidData("USDC path vector value is malformed.")
        }
        guard !valueRep.isInlined, !valueRep.isCompressed else {
            throw USDImportError.invalidData("USDC path vector value has unsupported representation bits.")
        }
        guard valueRep.payload != 0 else {
            throw USDImportError.invalidData("USDC path vector payload offset is missing.")
        }
        let paths = try crate.readPaths()
        var cursor = try payloadOffset(valueRep, label: "path vector")
        let count = try checkedInt(try crate.readFileUInt64(at: cursor), label: "USDC path vector count")
        cursor += MemoryLayout<UInt64>.size
        var values: [String] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            let pathIndex = try checkedInt(
                UInt64(try crate.readFileUInt32(at: cursor)),
                label: "USDC path vector path index"
            )
            cursor += MemoryLayout<UInt32>.size
            guard pathIndex < paths.count else {
                throw USDImportError.invalidData("USDC path vector references a path outside PATHS.")
            }
            values.append(paths[pathIndex])
        }
        return values
    }

    private func readTokenListOperation(_ valueRep: USDCCrateValueRep) throws -> USDCListOperation<String> {
        try readIndexedStringListOperation(
            valueRep,
            expectedType: .tokenListOperation,
            label: "token list operation",
            values: tokens,
            missingValueMessage: "USDC token list operation references a token outside TOKENS."
        )
    }

    private func readStringListOperation(_ valueRep: USDCCrateValueRep) throws -> USDCListOperation<String> {
        try readIndexedStringListOperation(
            valueRep,
            expectedType: .stringListOperation,
            label: "string list operation",
            values: strings,
            missingValueMessage: "USDC string list operation references a string outside STRINGS."
        )
    }

    private func readPathListOperation(_ valueRep: USDCCrateValueRep) throws -> USDCListOperation<String> {
        let paths = try crate.readPaths()
        return try readIndexedStringListOperation(
            valueRep,
            expectedType: .pathListOperation,
            label: "path list operation",
            values: paths,
            missingValueMessage: "USDC path list operation references a path outside PATHS."
        )
    }

    private func readReferenceListOperation(_ valueRep: USDCCrateValueRep) throws -> USDCListOperation<USDCReference> {
        try readListOperation(valueRep, expectedType: .referenceListOperation, label: "reference list operation") { cursor in
            try readReference(cursor: &cursor)
        }
    }

    private func readPayloadListOperation(_ valueRep: USDCCrateValueRep) throws -> USDCListOperation<USDCPayload> {
        try readListOperation(valueRep, expectedType: .payloadListOperation, label: "payload list operation") { cursor in
            try readPayload(cursor: &cursor)
        }
    }

    private func readPayloadValue(_ valueRep: USDCCrateValueRep) throws -> USDCPayload {
        guard valueRep.type == .payload, !valueRep.isArray else {
            throw USDImportError.invalidData("USDC payload value is malformed.")
        }
        guard !valueRep.isInlined, !valueRep.isCompressed else {
            throw USDImportError.invalidData("USDC payload value has unsupported representation bits.")
        }
        guard valueRep.payload != 0 else {
            throw USDImportError.invalidData("USDC payload value offset is missing.")
        }
        var cursor = try payloadOffset(valueRep, label: "payload")
        return try readPayload(cursor: &cursor)
    }

    private func readReference(cursor: inout Int) throws -> USDCReference {
        let assetPath = try readStringIndex(cursor: &cursor, label: "USDC reference asset path")
        let primPath = try readPathIndex(cursor: &cursor, label: "USDC reference prim path")
        let layerOffset = try readLayerOffset(cursor: &cursor, label: "USDC reference layer offset")
        let customData = try readDictionary(cursor: &cursor, label: "USDC reference custom data")
        return USDCReference(assetPath: assetPath, primPath: primPath, layerOffset: layerOffset, customData: customData)
    }

    private func readPayload(cursor: inout Int) throws -> USDCPayload {
        let assetPath = try readStringIndex(cursor: &cursor, label: "USDC payload asset path")
        let primPath = try readPathIndex(cursor: &cursor, label: "USDC payload prim path")
        let layerOffset: USDLayerOffset
        if crate.version >= USDCCrateVersion(major: 0, minor: 8, patch: 0) {
            layerOffset = try readLayerOffset(cursor: &cursor, label: "USDC payload layer offset")
        } else {
            layerOffset = .identity
        }
        return USDCPayload(assetPath: assetPath, primPath: primPath, layerOffset: layerOffset)
    }

    private func readStringIndex(cursor: inout Int, label: String) throws -> String {
        let stringIndex = try checkedInt(UInt64(try crate.readFileUInt32(at: cursor)), label: "\(label) string index")
        cursor += MemoryLayout<UInt32>.size
        guard stringIndex < strings.count else {
            throw USDImportError.invalidData("\(label) references a string outside STRINGS.")
        }
        return strings[stringIndex]
    }

    private func readPathIndex(cursor: inout Int, label: String) throws -> String {
        let paths = try crate.readPaths()
        let pathIndex = try checkedInt(UInt64(try crate.readFileUInt32(at: cursor)), label: "\(label) path index")
        cursor += MemoryLayout<UInt32>.size
        guard pathIndex < paths.count else {
            throw USDImportError.invalidData("\(label) references a path outside PATHS.")
        }
        return paths[pathIndex]
    }

    private func readLayerOffset(cursor: inout Int, label: String) throws -> USDLayerOffset {
        let offset = try readFloat64(cursor: &cursor, label: "\(label) offset")
        let scale = try readFloat64(cursor: &cursor, label: "\(label) scale")
        return USDLayerOffset(offset: offset, scale: scale)
    }

    private func readDictionaryValue(_ valueRep: USDCCrateValueRep) throws -> [String: USDCLayerFieldValue] {
        guard valueRep.type == .dictionary, !valueRep.isArray else {
            throw USDImportError.invalidData("USDC dictionary value is malformed.")
        }
        guard !valueRep.isInlined, !valueRep.isCompressed else {
            throw USDImportError.invalidData("USDC dictionary value has unsupported representation bits.")
        }
        guard valueRep.payload != 0 else {
            return [:]
        }
        var cursor = try payloadOffset(valueRep, label: "dictionary")
        return try readDictionary(cursor: &cursor, label: "USDC dictionary")
    }

    private func readDictionary(cursor: inout Int, label: String) throws -> [String: USDCLayerFieldValue] {
        let count = try checkedInt(try crate.readFileUInt64(at: cursor), label: "\(label) dictionary count")
        cursor += MemoryLayout<UInt64>.size
        var dictionary: [String: USDCLayerFieldValue] = [:]
        dictionary.reserveCapacity(count)
        for _ in 0..<count {
            let key = try readStringIndex(cursor: &cursor, label: "\(label) key")
            let value = try readDictionaryEntryValue(cursor: &cursor, label: "\(label) value")
            guard dictionary.updateValue(value, forKey: key) == nil else {
                throw USDImportError.invalidData("\(label) contains duplicate key '\(key)'.")
            }
        }
        return dictionary
    }

    private func readDictionaryEntryValue(cursor: inout Int, label: String) throws -> USDCLayerFieldValue {
        let valueRepCursor = try recursivePayloadEnd(start: cursor, label: "\(label) recursive payload")
        let nextCursorResult = valueRepCursor.addingReportingOverflow(MemoryLayout<UInt64>.size)
        guard !nextCursorResult.overflow else {
            throw USDImportError.invalidData("\(label) value representation exceeds platform range.")
        }
        let valueRep = USDCCrateValueRep(rawValue: try crate.readFileUInt64(at: valueRepCursor))
        cursor = nextCursorResult.partialValue
        guard let value = try readLayerFieldValue(valueRep) else {
            throw USDImportError.unsupportedFeature("\(label) type \(String(describing: valueRep.type)) is not materialized yet.")
        }
        return value
    }

    private func readIndexedStringListOperation(
        _ valueRep: USDCCrateValueRep,
        expectedType: USDCCrateValueType,
        label: String,
        values: [String],
        missingValueMessage: String
    ) throws -> USDCListOperation<String> {
        try readListOperation(valueRep, expectedType: expectedType, label: label) { cursor in
            let index = try checkedInt(
                UInt64(try crate.readFileUInt32(at: cursor)),
                label: "USDC \(label) item index"
            )
            cursor += MemoryLayout<UInt32>.size
            guard index < values.count else {
                throw USDImportError.invalidData(missingValueMessage)
            }
            return values[index]
        }
    }

    private func readListOperation<Item: Sendable & Equatable>(
        _ valueRep: USDCCrateValueRep,
        expectedType: USDCCrateValueType,
        label: String,
        readItem: (inout Int) throws -> Item
    ) throws -> USDCListOperation<Item> {
        guard valueRep.type == expectedType, !valueRep.isArray else {
            throw USDImportError.invalidData("USDC \(label) value is malformed.")
        }
        guard !valueRep.isInlined, !valueRep.isCompressed else {
            throw USDImportError.invalidData("USDC \(label) value has unsupported representation bits.")
        }
        guard valueRep.payload != 0 else {
            throw USDImportError.invalidData("USDC \(label) payload offset is missing.")
        }
        var cursor = try payloadOffset(valueRep, label: label)
        let header = try crate.readFileBytes(at: cursor, byteCount: 1)[0]
        cursor += 1
        guard header & ~USDCListOperationHeader.allKnownBits == 0 else {
            throw USDImportError.invalidData("USDC \(label) header contains unknown bits.")
        }

        var listOperation = USDCListOperation<Item>(
            isExplicit: header & USDCListOperationHeader.isExplicitBit != 0
        )
        if header & USDCListOperationHeader.hasExplicitItemsBit != 0 {
            listOperation.explicitItems = try readListOperationItems(cursor: &cursor, label: label, readItem: readItem)
        }
        if header & USDCListOperationHeader.hasAddedItemsBit != 0 {
            listOperation.addedItems = try readListOperationItems(cursor: &cursor, label: label, readItem: readItem)
        }
        if header & USDCListOperationHeader.hasPrependedItemsBit != 0 {
            listOperation.prependedItems = try readListOperationItems(cursor: &cursor, label: label, readItem: readItem)
        }
        if header & USDCListOperationHeader.hasAppendedItemsBit != 0 {
            listOperation.appendedItems = try readListOperationItems(cursor: &cursor, label: label, readItem: readItem)
        }
        if header & USDCListOperationHeader.hasDeletedItemsBit != 0 {
            listOperation.deletedItems = try readListOperationItems(cursor: &cursor, label: label, readItem: readItem)
        }
        if header & USDCListOperationHeader.hasOrderedItemsBit != 0 {
            listOperation.orderedItems = try readListOperationItems(cursor: &cursor, label: label, readItem: readItem)
        }
        return listOperation
    }

    private func readListOperationItems<Item>(
        cursor: inout Int,
        label: String,
        readItem: (inout Int) throws -> Item
    ) throws -> [Item] {
        let count = try checkedInt(try crate.readFileUInt64(at: cursor), label: "USDC \(label) item count")
        cursor += MemoryLayout<UInt64>.size
        var items: [Item] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            items.append(try readItem(&cursor))
        }
        return items
    }

    private func readFloatScalar(_ valueRep: USDCCrateValueRep) throws -> Float32 {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC float value is marked as an array.")
        }
        if valueRep.isInlined {
            let bits = UInt32(valueRep.payload & UInt64(UInt32.max))
            return Float32(bitPattern: bits)
        }
        let bytes = try crate.readFileBytes(
            at: try payloadOffset(valueRep, label: "float"),
            byteCount: MemoryLayout<UInt32>.size
        )
        return littleEndianFloat32(bytes[0..<4])
    }

    private func readDoubleScalar(_ valueRep: USDCCrateValueRep) throws -> Double {
        if valueRep.isInlined {
            let floatBits = UInt32(valueRep.payload & UInt64(UInt32.max))
            return Double(Float32(bitPattern: floatBits))
        }
        let bytes = try crate.readFileBytes(
            at: try payloadOffset(valueRep, label: "double"),
            byteCount: MemoryLayout<UInt64>.size
        )
        let bits = littleEndianUInt64(bytes[0..<bytes.count])
        return Double(bitPattern: bits)
    }

    private func readIntScalar(_ valueRep: USDCCrateValueRep) throws -> Int {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC int value is marked as an array.")
        }
        if valueRep.isInlined {
            let bits = UInt32(valueRep.payload & UInt64(UInt32.max))
            return Int(Int32(bitPattern: bits))
        }
        let bytes = try crate.readFileBytes(
            at: try payloadOffset(valueRep, label: "int"),
            byteCount: MemoryLayout<UInt32>.size
        )
        return Int(littleEndianInt32(bytes[0..<4]))
    }

    private func readVec3fScalar(_ valueRep: USDCCrateValueRep) throws -> USDCVector3D {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec3f value is marked as an array.")
        }
        if valueRep.isInlined {
            return try inlinedVector3(valueRep, scalarName: "vec3f")
        }
        var cursor = try payloadOffset(valueRep, label: "vec3f")
        let vector = try readVector3Float32(cursor: &cursor, label: "USDC vec3f")
        return vector
    }

    private func readVec3dScalar(_ valueRep: USDCCrateValueRep) throws -> USDCVector3D {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec3d value is marked as an array.")
        }
        if valueRep.isInlined {
            return try inlinedVector3(valueRep, scalarName: "vec3d")
        }
        var cursor = try payloadOffset(valueRep, label: "vec3d")
        let vector = try readVector3Float64(cursor: &cursor, label: "USDC vec3d")
        return vector
    }

    private func readVec2fScalar(_ valueRep: USDCCrateValueRep) throws -> USDPoint2D {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec2f value is marked as an array.")
        }
        if valueRep.isInlined {
            return try inlinedVector2(valueRep, scalarName: "vec2f")
        }
        var cursor = try payloadOffset(valueRep, label: "vec2f")
        return try readVector2Float32(cursor: &cursor, label: "USDC vec2f")
    }

    private func readVec2dScalar(_ valueRep: USDCCrateValueRep) throws -> USDPoint2D {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec2d value is marked as an array.")
        }
        if valueRep.isInlined {
            return try inlinedVector2(valueRep, scalarName: "vec2d")
        }
        var cursor = try payloadOffset(valueRep, label: "vec2d")
        return try readVector2Float64(cursor: &cursor, label: "USDC vec2d")
    }

    private func readQuatfScalar(_ valueRep: USDCCrateValueRep) throws -> USDCQuaternion {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC quatf value is marked as an array.")
        }
        guard !valueRep.isInlined else {
            throw USDImportError.invalidData("USDC quatf value is unexpectedly inlined.")
        }
        var cursor = try payloadOffset(valueRep, label: "quatf")
        return try readQuaternionFloat32(cursor: &cursor, label: "USDC quatf")
    }

    private func readQuatdScalar(_ valueRep: USDCCrateValueRep) throws -> USDCQuaternion {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC quatd value is marked as an array.")
        }
        guard !valueRep.isInlined else {
            throw USDImportError.invalidData("USDC quatd value is unexpectedly inlined.")
        }
        var cursor = try payloadOffset(valueRep, label: "quatd")
        return try readQuaternionFloat64(cursor: &cursor, label: "USDC quatd")
    }

    private func readMatrix4dScalar(_ valueRep: USDCCrateValueRep) throws -> USDCMatrix4x4 {
        guard !valueRep.isArray else {
            throw USDImportError.invalidData("USDC matrix4d value is marked as an array.")
        }
        if valueRep.isInlined {
            var values = USDCMatrix4x4.identity.values
            let bytes = inlinedInt8Bytes(valueRep, count: 4)
            for index in 0..<4 {
                values[index * 4 + index] = Double(bytes[index])
            }
            return USDCMatrix4x4(values: values)
        }
        var cursor = try payloadOffset(valueRep, label: "matrix4d")
        var values: [Double] = []
        values.reserveCapacity(16)
        for _ in 0..<16 {
            values.append(try readFloat64(cursor: &cursor, label: "USDC matrix4d component"))
        }
        guard values.allSatisfy(\.isFinite) else {
            throw USDImportError.invalidData("USDC matrix4d contains a non-finite component.")
        }
        return USDCMatrix4x4(values: values)
    }

    private func readDoubleVectorValues(_ valueRep: USDCCrateValueRep) throws -> [Double] {
        guard valueRep.type == .doubleVector, !valueRep.isArray, !valueRep.isInlined else {
            throw USDImportError.invalidData("USDC timeSamples references a malformed doubleVector.")
        }
        var cursor = try payloadOffset(valueRep, label: "doubleVector")
        let count = try checkedInt(try crate.readFileUInt64(at: cursor), label: "USDC doubleVector count")
        cursor += MemoryLayout<UInt64>.size
        var values: [Double] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readFloat64(cursor: &cursor, label: "USDC doubleVector value"))
        }
        return values
    }

    private func recursivePayloadEnd(start: Int, label: String) throws -> Int {
        let rawOffset = try crate.readFileUInt64(at: start)
        guard rawOffset <= UInt64(Int64.max) else {
            throw USDImportError.invalidData("\(label) recursive offset exceeds platform range.")
        }
        let offset = Int64(bitPattern: rawOffset)
        guard offset >= Int64(MemoryLayout<Int64>.size) else {
            throw USDImportError.invalidData("\(label) recursive offset is malformed.")
        }
        let endResult = Int64(start).addingReportingOverflow(offset)
        guard !endResult.overflow, endResult.partialValue >= 0, endResult.partialValue <= Int64(Int.max) else {
            throw USDImportError.invalidData("\(label) recursive offset exceeds platform range.")
        }
        return Int(endResult.partialValue)
    }

    private func readBoolArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Bool] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC bool array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "bool array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC bool array count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: count,
            label: "bool array"
        )
        return bytes.map { $0 != 0 }
    }

    private func readUInt8ArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Int] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC uchar array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "uchar array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC uchar array count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: count,
            label: "uchar array"
        )
        return bytes.map(Int.init)
    }

    private func readIntArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Int] {
        try readUInt32ArrayPayload(valueRep, label: "int array").map {
            Int(Int32(bitPattern: $0))
        }
    }

    private func readUInt32ArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Int] {
        try readUInt32ArrayPayload(valueRep, label: "uint array").map {
            try intValue(UInt64($0), label: "USDC uint array value")
        }
    }

    private func readInt64ArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Int] {
        try readUInt64ArrayPayload(valueRep, label: "int64 array").map {
            try intValue(Int64(bitPattern: $0), label: "USDC int64 array value")
        }
    }

    private func readUInt64ArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Int] {
        try readUInt64ArrayPayload(valueRep, label: "uint64 array").map {
            try intValue($0, label: "USDC uint64 array value")
        }
    }

    private func readUInt32ArrayPayload(_ valueRep: USDCCrateValueRep, label: String) throws -> [UInt32] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC \(label) value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: label)
        let count = try readArrayCount(cursor: &cursor, label: "USDC \(label) count")
        if valueRep.isCompressed {
            guard crate.version >= USDCCrateVersion(major: 0, minor: 5, patch: 0) else {
                throw USDImportError.invalidData("USDC \(label) is marked compressed before compression support.")
            }
            let compressedByteCount = try checkedInt(
                try crate.readFileUInt64(at: cursor),
                label: "USDC compressed \(label) byte count"
            )
            cursor += MemoryLayout<UInt64>.size
            let compressedBytes = try crate.readFileBytes(at: cursor, byteCount: compressedByteCount)
            return try USDCIntegerCompression.decompressUInt32(compressedBytes, count: count)
        }
        let byteCount = try checkedMultiplication(count, MemoryLayout<UInt32>.size, label: "USDC \(label) byte count")
        let bytes = try crate.readFileBytes(at: cursor, byteCount: byteCount)
        var values: [UInt32] = []
        values.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            values.append(littleEndianUInt32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<UInt32>.size
        }
        return values
    }

    private func readUInt64ArrayPayload(_ valueRep: USDCCrateValueRep, label: String) throws -> [UInt64] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC \(label) value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: label)
        let count = try readArrayCount(cursor: &cursor, label: "USDC \(label) count")
        let byteCount = try checkedMultiplication(count, MemoryLayout<UInt64>.size, label: "USDC \(label) byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: label
        )
        var values: [UInt64] = []
        values.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            values.append(littleEndianUInt64(bytes[byteCursor..<(byteCursor + 8)]))
            byteCursor += MemoryLayout<UInt64>.size
        }
        return values
    }

    private func readVec3fArrayValue(_ valueRep: USDCCrateValueRep) throws -> [USDPoint3D] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec3f array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "vec3f array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC vec3f array count")
        let scalarCount = try checkedMultiplication(count, 3, label: "USDC vec3f scalar count")
        let byteCount = try checkedMultiplication(scalarCount, MemoryLayout<Float32>.size, label: "USDC vec3f array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "vec3f array"
        )
        var points: [USDPoint3D] = []
        points.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let x = Double(littleEndianFloat32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<Float32>.size
            let y = Double(littleEndianFloat32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<Float32>.size
            let z = Double(littleEndianFloat32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<Float32>.size
            guard x.isFinite, y.isFinite, z.isFinite else {
                throw USDImportError.invalidData("USDC vec3f array contains a non-finite point.")
            }
            points.append(USDPoint3D(x: x, y: y, z: z))
        }
        return points
    }

    private func readVec3dArrayValue(_ valueRep: USDCCrateValueRep) throws -> [USDPoint3D] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec3d array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "vec3d array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC vec3d array count")
        let scalarCount = try checkedMultiplication(count, 3, label: "USDC vec3d scalar count")
        let byteCount = try checkedMultiplication(scalarCount, MemoryLayout<UInt64>.size, label: "USDC vec3d array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "vec3d array"
        )
        var points: [USDPoint3D] = []
        points.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let x = try float64(bytes[byteCursor..<(byteCursor + 8)], label: "USDC vec3d array x")
            byteCursor += MemoryLayout<UInt64>.size
            let y = try float64(bytes[byteCursor..<(byteCursor + 8)], label: "USDC vec3d array y")
            byteCursor += MemoryLayout<UInt64>.size
            let z = try float64(bytes[byteCursor..<(byteCursor + 8)], label: "USDC vec3d array z")
            byteCursor += MemoryLayout<UInt64>.size
            points.append(USDPoint3D(x: x, y: y, z: z))
        }
        return points
    }

    private func readFloatArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Double] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC float array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "float array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC float array count")
        let byteCount = try checkedMultiplication(count, MemoryLayout<Float32>.size, label: "USDC float array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "float array"
        )
        var values: [Double] = []
        values.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let value = Double(littleEndianFloat32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<Float32>.size
            guard value.isFinite else {
                throw USDImportError.invalidData("USDC float array contains a non-finite value.")
            }
            values.append(value)
        }
        return values
    }

    private func readDoubleArrayValue(_ valueRep: USDCCrateValueRep) throws -> [Double] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC double array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "double array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC double array count")
        let byteCount = try checkedMultiplication(count, MemoryLayout<UInt64>.size, label: "USDC double array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "double array"
        )
        var values: [Double] = []
        values.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let value = try float64(bytes[byteCursor..<(byteCursor + 8)], label: "USDC double array value")
            byteCursor += MemoryLayout<UInt64>.size
            values.append(value)
        }
        return values
    }

    private func readVec2fArrayValue(_ valueRep: USDCCrateValueRep) throws -> [USDPoint2D] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec2f array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "vec2f array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC vec2f array count")
        let scalarCount = try checkedMultiplication(count, 2, label: "USDC vec2f scalar count")
        let byteCount = try checkedMultiplication(scalarCount, MemoryLayout<Float32>.size, label: "USDC vec2f array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "vec2f array"
        )
        var points: [USDPoint2D] = []
        points.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let x = Double(littleEndianFloat32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<Float32>.size
            let y = Double(littleEndianFloat32(bytes[byteCursor..<(byteCursor + 4)]))
            byteCursor += MemoryLayout<Float32>.size
            guard x.isFinite, y.isFinite else {
                throw USDImportError.invalidData("USDC vec2f array contains a non-finite point.")
            }
            points.append(USDPoint2D(x: x, y: y))
        }
        return points
    }

    private func readVec2dArrayValue(_ valueRep: USDCCrateValueRep) throws -> [USDPoint2D] {
        guard valueRep.isArray else {
            throw USDImportError.invalidData("USDC vec2d array value is missing the array bit.")
        }
        guard valueRep.payload != 0 else {
            return []
        }
        var cursor = try arrayPayloadCursor(valueRep, label: "vec2d array")
        let count = try readArrayCount(cursor: &cursor, label: "USDC vec2d array count")
        let scalarCount = try checkedMultiplication(count, 2, label: "USDC vec2d scalar count")
        let byteCount = try checkedMultiplication(scalarCount, MemoryLayout<UInt64>.size, label: "USDC vec2d array byte count")
        let bytes = try arrayBytes(
            valueRep,
            cursor: &cursor,
            byteCount: byteCount,
            label: "vec2d array"
        )
        var points: [USDPoint2D] = []
        points.reserveCapacity(count)
        var byteCursor = 0
        for _ in 0..<count {
            let x = try float64(bytes[byteCursor..<(byteCursor + 8)], label: "USDC vec2d array x")
            byteCursor += MemoryLayout<UInt64>.size
            let y = try float64(bytes[byteCursor..<(byteCursor + 8)], label: "USDC vec2d array y")
            byteCursor += MemoryLayout<UInt64>.size
            points.append(USDPoint2D(x: x, y: y))
        }
        return points
    }

    private func arrayBytes(
        _ valueRep: USDCCrateValueRep,
        cursor: inout Int,
        byteCount: Int,
        label: String
    ) throws -> [UInt8] {
        guard valueRep.isCompressed else {
            return try crate.readFileBytes(at: cursor, byteCount: byteCount)
        }
        guard crate.version >= USDCCrateVersion(major: 0, minor: 5, patch: 0) else {
            throw USDImportError.invalidData("USDC \(label) is marked compressed before compression support.")
        }
        let compressedByteCount = try checkedInt(
            try crate.readFileUInt64(at: cursor),
            label: "USDC compressed \(label) byte count"
        )
        cursor += MemoryLayout<UInt64>.size
        let compressedBytes = try crate.readFileBytes(at: cursor, byteCount: compressedByteCount)
        return try USDCFastCompression.decompress(compressedBytes, expectedByteCount: byteCount)
    }

    private func arrayPayloadCursor(_ valueRep: USDCCrateValueRep, label: String) throws -> Int {
        var cursor = try payloadOffset(valueRep, label: label)
        if crate.version < USDCCrateVersion(major: 0, minor: 5, patch: 0) {
            let shapeRank = try crate.readFileUInt32(at: cursor)
            cursor += MemoryLayout<UInt32>.size
            guard shapeRank == 1 else {
                throw USDImportError.unsupportedFeature("Only one-dimensional USDC \(label)s are supported.")
            }
        }
        return cursor
    }

    private func inlinedVector3(_ valueRep: USDCCrateValueRep, scalarName: String) throws -> USDCVector3D {
        let bytes = inlinedInt8Bytes(valueRep, count: 3)
        let vector = USDCVector3D(x: Double(bytes[0]), y: Double(bytes[1]), z: Double(bytes[2]))
        guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
            throw USDImportError.invalidData("USDC \(scalarName) contains a non-finite component.")
        }
        return vector
    }

    private func inlinedVector2(_ valueRep: USDCCrateValueRep, scalarName: String) throws -> USDPoint2D {
        let bytes = inlinedInt8Bytes(valueRep, count: 2)
        let point = USDPoint2D(x: Double(bytes[0]), y: Double(bytes[1]))
        guard point.x.isFinite, point.y.isFinite else {
            throw USDImportError.invalidData("USDC \(scalarName) contains a non-finite component.")
        }
        return point
    }

    private func inlinedInt8Bytes(_ valueRep: USDCCrateValueRep, count: Int) -> [Int8] {
        (0..<count).map { index in
            let byte = UInt8((valueRep.payload >> UInt64(index * 8)) & 0xff)
            return Int8(bitPattern: byte)
        }
    }

    private func readVector2Float32(cursor: inout Int, label: String) throws -> USDPoint2D {
        let byteCount = 2 * MemoryLayout<Float32>.size
        let bytes = try crate.readFileBytes(at: cursor, byteCount: byteCount)
        cursor += byteCount
        let x = Double(littleEndianFloat32(bytes[0..<4]))
        let y = Double(littleEndianFloat32(bytes[4..<8]))
        guard x.isFinite, y.isFinite else {
            throw USDImportError.invalidData("\(label) contains a non-finite component.")
        }
        return USDPoint2D(x: x, y: y)
    }

    private func readVector2Float64(cursor: inout Int, label: String) throws -> USDPoint2D {
        let x = try readFloat64(cursor: &cursor, label: "\(label) x")
        let y = try readFloat64(cursor: &cursor, label: "\(label) y")
        guard x.isFinite, y.isFinite else {
            throw USDImportError.invalidData("\(label) contains a non-finite component.")
        }
        return USDPoint2D(x: x, y: y)
    }

    private func readVector3Float32(cursor: inout Int, label: String) throws -> USDCVector3D {
        let byteCount = 3 * MemoryLayout<Float32>.size
        let bytes = try crate.readFileBytes(at: cursor, byteCount: byteCount)
        cursor += byteCount
        let x = Double(littleEndianFloat32(bytes[0..<4]))
        let y = Double(littleEndianFloat32(bytes[4..<8]))
        let z = Double(littleEndianFloat32(bytes[8..<12]))
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw USDImportError.invalidData("\(label) contains a non-finite component.")
        }
        return USDCVector3D(x: x, y: y, z: z)
    }

    private func readVector3Float64(cursor: inout Int, label: String) throws -> USDCVector3D {
        let x = try readFloat64(cursor: &cursor, label: "\(label) x")
        let y = try readFloat64(cursor: &cursor, label: "\(label) y")
        let z = try readFloat64(cursor: &cursor, label: "\(label) z")
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw USDImportError.invalidData("\(label) contains a non-finite component.")
        }
        return USDCVector3D(x: x, y: y, z: z)
    }

    private func readQuaternionFloat32(cursor: inout Int, label: String) throws -> USDCQuaternion {
        let byteCount = 4 * MemoryLayout<Float32>.size
        let bytes = try crate.readFileBytes(at: cursor, byteCount: byteCount)
        cursor += byteCount
        // GfQuat POD payloads store imaginary xyz before real, although USDA text prints real first.
        let imaginaryX = Double(littleEndianFloat32(bytes[0..<4]))
        let imaginaryY = Double(littleEndianFloat32(bytes[4..<8]))
        let imaginaryZ = Double(littleEndianFloat32(bytes[8..<12]))
        let real = Double(littleEndianFloat32(bytes[12..<16]))
        guard real.isFinite, imaginaryX.isFinite, imaginaryY.isFinite, imaginaryZ.isFinite else {
            throw USDImportError.invalidData("\(label) contains a non-finite component.")
        }
        return USDCQuaternion(
            real: real,
            imaginaryX: imaginaryX,
            imaginaryY: imaginaryY,
            imaginaryZ: imaginaryZ
        )
    }

    private func readQuaternionFloat64(cursor: inout Int, label: String) throws -> USDCQuaternion {
        // GfQuat POD payloads store imaginary xyz before real, although USDA text prints real first.
        let imaginaryX = try readFloat64(cursor: &cursor, label: "\(label) imaginary x")
        let imaginaryY = try readFloat64(cursor: &cursor, label: "\(label) imaginary y")
        let imaginaryZ = try readFloat64(cursor: &cursor, label: "\(label) imaginary z")
        let real = try readFloat64(cursor: &cursor, label: "\(label) real")
        return USDCQuaternion(
            real: real,
            imaginaryX: imaginaryX,
            imaginaryY: imaginaryY,
            imaginaryZ: imaginaryZ
        )
    }

    private func readFloat64(cursor: inout Int, label: String) throws -> Double {
        let bytes = try crate.readFileBytes(at: cursor, byteCount: MemoryLayout<UInt64>.size)
        cursor += MemoryLayout<UInt64>.size
        let value = Double(bitPattern: littleEndianUInt64(bytes[0..<bytes.count]))
        guard value.isFinite else {
            throw USDImportError.invalidData("\(label) is not finite.")
        }
        return value
    }

    private func float64(_ bytes: ArraySlice<UInt8>, label: String) throws -> Double {
        let value = Double(bitPattern: littleEndianUInt64(bytes))
        guard value.isFinite else {
            throw USDImportError.invalidData("\(label) is not finite.")
        }
        return value
    }

    private func readArrayCount(cursor: inout Int, label: String) throws -> Int {
        if crate.version < USDCCrateVersion(major: 0, minor: 7, patch: 0) {
            let count = try crate.readFileUInt32(at: cursor)
            cursor += MemoryLayout<UInt32>.size
            return Int(count)
        }
        let count = try checkedInt(try crate.readFileUInt64(at: cursor), label: label)
        cursor += MemoryLayout<UInt64>.size
        return count
    }

    private func payloadOffset(_ valueRep: USDCCrateValueRep, label: String) throws -> Int {
        try checkedInt(valueRep.payload, label: "USDC \(label) payload offset")
    }

    private func checkedInt(_ value: UInt64, label: String) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw USDImportError.invalidData("\(label) exceeds platform range.")
        }
        return Int(value)
    }

    private func intValue(_ value: Int64, label: String) throws -> Int {
        guard let int = Int(exactly: value) else {
            throw USDImportError.invalidData("\(label) exceeds platform range.")
        }
        return int
    }

    private func intValue(_ value: UInt64, label: String) throws -> Int {
        guard let int = Int(exactly: value) else {
            throw USDImportError.invalidData("\(label) exceeds platform range.")
        }
        return int
    }

    private func checkedMultiplication(_ lhs: Int, _ rhs: Int, label: String) throws -> Int {
        guard lhs >= 0, rhs >= 0, lhs <= Int.max / rhs else {
            throw USDImportError.invalidData("\(label) exceeds platform range.")
        }
        return lhs * rhs
    }

    private func littleEndianUInt64(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.enumerated().reduce(UInt64(0)) { result, element in
            result | (UInt64(element.element) << UInt64(element.offset * 8))
        }
    }

    private func littleEndianInt32(_ bytes: ArraySlice<UInt8>) -> Int32 {
        Int32(bitPattern: littleEndianUInt32(bytes))
    }

    private func littleEndianFloat32(_ bytes: ArraySlice<UInt8>) -> Float32 {
        Float32(bitPattern: littleEndianUInt32(bytes))
    }

    private func littleEndianUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.enumerated().reduce(UInt32(0)) { result, element in
            result | (UInt32(element.element) << UInt32(element.offset * 8))
        }
    }
}

private enum USDCListOperationHeader {
    static let isExplicitBit: UInt8 = 1 << 0
    static let hasExplicitItemsBit: UInt8 = 1 << 1
    static let hasAddedItemsBit: UInt8 = 1 << 2
    static let hasDeletedItemsBit: UInt8 = 1 << 3
    static let hasOrderedItemsBit: UInt8 = 1 << 4
    static let hasPrependedItemsBit: UInt8 = 1 << 5
    static let hasAppendedItemsBit: UInt8 = 1 << 6
    static let allKnownBits: UInt8 =
        isExplicitBit
        | hasExplicitItemsBit
        | hasAddedItemsBit
        | hasDeletedItemsBit
        | hasOrderedItemsBit
        | hasPrependedItemsBit
        | hasAppendedItemsBit
}
