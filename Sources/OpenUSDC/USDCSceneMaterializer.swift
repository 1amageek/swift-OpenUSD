import OpenUSD
import Foundation

struct USDCSceneMaterializer {
    private let crate: USDCCrateFile
    private let options: USDReadingOptions
    private let sections: USDCCrateStructuralSections

    init(crate: USDCCrateFile, options: USDReadingOptions = .default, sections: USDCCrateStructuralSections) {
        self.crate = crate
        self.options = options
        self.sections = sections
    }

    private func makeValueDecoder() -> USDCCrateValueDecoder {
        USDCCrateValueDecoder(
            crate: crate,
            tokens: sections.tokens,
            strings: sections.strings,
            paths: sections.paths
        )
    }

    func readScene() throws -> USDScene {
        let valueDecoder = makeValueDecoder()

        let specsByPath = try buildSpecsByPath(
            specs: sections.specs,
            paths: sections.paths,
            fields: sections.fields,
            fieldSetIndexes: sections.fieldSetIndexes,
            tokens: sections.tokens
        )
        try validatePrimChildren(in: specsByPath, valueDecoder: valueDecoder)

        guard let rootSpec = specsByPath["/"] else {
            throw USDError.invalidData("USDC scene is missing the pseudo-root spec.")
        }
        let rootFields = rootSpec.fields
        let defaultPrim = try rootFields["defaultPrim"].map { try valueDecoder.readStringLike($0) }
        // Upstream USD falls back to 0.01 (centimeters) when layer metadata
        // does not author metersPerUnit.
        let metersPerUnit = try rootFields["metersPerUnit"].map { try valueDecoder.readDouble($0) } ?? 0.01
        guard metersPerUnit.isFinite, metersPerUnit > 0 else {
            throw USDError.invalidData("USDC metersPerUnit must be a positive finite value.")
        }
        let upAxisToken = try rootFields["upAxis"].map { try valueDecoder.readStringLike($0) }
        let upAxis: USDUpAxis
        if let upAxisToken {
            guard let parsed = USDUpAxis(rawValue: upAxisToken) else {
                throw USDError.invalidData("Unsupported USDC upAxis \(upAxisToken).")
            }
            upAxis = parsed
        } else {
            upAxis = .y
        }

        let meshes = try materializeMeshes(specsByPath: specsByPath, valueDecoder: valueDecoder)
        guard !meshes.isEmpty else {
            throw USDError.invalidData("USDC scene contains no Mesh prims.")
        }
        return USDScene(defaultPrim: defaultPrim, metersPerUnit: metersPerUnit, upAxis: upAxis, meshes: meshes)
    }

    func readPrimTransforms() throws -> [String: USDTransformMatrix4x4] {
        try readPrimTransformInfo().primTransforms
    }

    func readPrimTransformInfo() throws -> (
        primTransforms: [String: USDTransformMatrix4x4],
        resetXformStackPrimPaths: Set<String>
    ) {
        let valueDecoder = makeValueDecoder()
        let specsByPath = try buildSpecsByPath(
            specs: sections.specs,
            paths: sections.paths,
            fields: sections.fields,
            fieldSetIndexes: sections.fieldSetIndexes,
            tokens: sections.tokens
        )
        try validatePrimChildren(in: specsByPath, valueDecoder: valueDecoder)
        var context = USDCTransformContext(specsByPath: specsByPath)
        var primTransforms: [String: USDTransformMatrix4x4] = [:]
        var resetXformStackPrimPaths: Set<String> = []
        for path in specsByPath.keys.sorted() where path != "/" {
            guard specsByPath[path]?.specType == .prim else {
                continue
            }
            let localTransform = try localTransform(
                forPrimPath: path,
                context: &context,
                valueDecoder: valueDecoder
            )
            if localTransform.resetsParentStack {
                resetXformStackPrimPaths.insert(path)
            }
            primTransforms[path] = try worldTransform(
                forPrimPath: path,
                context: &context,
                valueDecoder: valueDecoder
            ).usdTransformMatrix
        }
        return (primTransforms, resetXformStackPrimPaths)
    }

    private func buildSpecsByPath(
        specs: [USDCCrateSpec],
        paths: [String],
        fields: [USDCCrateField],
        fieldSetIndexes: [UInt32],
        tokens: [String]
    ) throws -> [String: USDCSpecRecord] {
        var records: [String: USDCSpecRecord] = [:]
        for spec in specs {
            let path = paths[Int(spec.pathIndex)]
            let fieldIndexes = try fieldIndexesForSpec(spec, fieldSetIndexes: fieldSetIndexes)
            var fieldReps: [String: USDCCrateValueRep] = [:]
            for fieldIndex in fieldIndexes {
                guard fieldIndex < UInt32(fields.count) else {
                    throw USDError.invalidData("USDC spec references a field outside FIELDS.")
                }
                let field = fields[Int(fieldIndex)]
                guard field.tokenIndex < UInt32(tokens.count) else {
                    throw USDError.invalidData("USDC field references a token outside TOKENS.")
                }
                let fieldName = tokens[Int(field.tokenIndex)]
                guard fieldReps[fieldName] == nil else {
                    throw USDError.invalidData("USDC spec contains duplicate field \(fieldName).")
                }
                fieldReps[fieldName] = field.valueRep
            }
            records[path] = USDCSpecRecord(specType: spec.specType, fields: fieldReps)
        }
        return records
    }

    private func validatePrimChildren(
        in specsByPath: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws {
        try USDCPrimChildrenValidator.validate(
            specsByPath.map { path, record in
                USDCPrimChildrenValidationRecord(
                    path: path,
                    specType: record.specType,
                    fields: record.fields
                )
            },
            valueDecoder: valueDecoder
        )
    }

    private func fieldIndexesForSpec(_ spec: USDCCrateSpec, fieldSetIndexes: [UInt32]) throws -> [UInt32] {
        var index = Int(spec.fieldSetIndex)
        guard index < fieldSetIndexes.count else {
            throw USDError.invalidData("USDC spec field set index is outside FIELDSETS.")
        }
        var fieldIndexes: [UInt32] = []
        while index < fieldSetIndexes.count {
            let fieldIndex = fieldSetIndexes[index]
            index += 1
            if fieldIndex == UInt32.max {
                return fieldIndexes
            }
            fieldIndexes.append(fieldIndex)
        }
        throw USDError.invalidData("USDC spec field set is unterminated.")
    }

    private func materializeMeshes(
        specsByPath: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [USDMesh] {
        var meshes: [USDMesh] = []
        let meshPrimPaths = try specsByPath.keys.sorted().filter { path in
            guard let record = specsByPath[path], record.specType == .prim else {
                return false
            }
            guard let typeNameRep = record.fields["typeName"] else {
                return false
            }
            if let specifierRep = record.fields["specifier"], try !isDefSpecifier(specifierRep) {
                return false
            }
            return try valueDecoder.readStringLike(typeNameRep) == "Mesh"
        }

        var context = USDCTransformContext(specsByPath: specsByPath)
        for meshPath in meshPrimPaths {
            let attributeRecords = context.attributes(forPrimPath: meshPath)
            let points = try requiredPointArray(
                named: "points",
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            let transform = try worldTransform(
                forPrimPath: meshPath,
                context: &context,
                valueDecoder: valueDecoder
            )
            let transformedPoints = try points.map { try transform.transform($0) }
            let normals = try optionalPointArray(
                named: "normals",
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            ) ?? []
            let transformedNormals = try normals.map { try transform.transform(normal: $0) }
            let normalsInterpolation = try optionalMetadataString(
                named: "interpolation",
                record: attributeRecords["normals"],
                valueDecoder: valueDecoder
            )
            let faceVertexCounts = try requiredIntArray(
                named: "faceVertexCounts",
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            let faceVertexIndices = try requiredIntArray(
                named: "faceVertexIndices",
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            try USDMesh.validateTopology(
                pointCount: transformedPoints.count,
                faceVertexCounts: faceVertexCounts,
                faceVertexIndices: faceVertexIndices
            )
            let orientation = try optionalOrientation(
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            let subdivisionScheme = try optionalString(
                named: "subdivisionScheme",
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            let textureCoordinates = try optionalTextureCoordinates(
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            let displayColor = try optionalDisplayColor(
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            let displayOpacity = try optionalDisplayOpacity(
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            if let textureCoordinates {
                try textureCoordinates.validate(pointCount: transformedPoints.count, faceVertexCounts: faceVertexCounts)
            }
            if let displayColor {
                try displayColor.validate(pointCount: transformedPoints.count, faceVertexCounts: faceVertexCounts)
            }
            if let displayOpacity {
                try displayOpacity.validate(pointCount: transformedPoints.count, faceVertexCounts: faceVertexCounts)
            }
            let extent = try optionalPointArray(
                named: "extent",
                attributeRecords: attributeRecords,
                valueDecoder: valueDecoder
            )
            if let extent, extent.count != 2 {
                throw USDError.invalidData("USDC Mesh extent must contain exactly two points.")
            }
            let transformedExtent = try transformedExtent(extent, applying: transform)
            meshes.append(USDMesh(
                name: primName(from: meshPath),
                primPath: meshPath,
                points: transformedPoints,
                faceVertexCounts: faceVertexCounts,
                faceVertexIndices: faceVertexIndices,
                normals: transformedNormals,
                normalsInterpolation: normalsInterpolation,
                orientation: orientation,
                subdivisionScheme: subdivisionScheme,
                textureCoordinates: textureCoordinates,
                displayColor: displayColor,
                displayOpacity: displayOpacity,
                extent: transformedExtent
            ))
        }
        return meshes
    }

    private func transformedExtent(
        _ extent: [USDPoint3D]?,
        applying transform: USDCMatrix4x4
    ) throws -> [USDPoint3D]? {
        guard let extent else {
            return nil
        }
        let minimum = extent[0]
        let maximum = extent[1]
        let corners = [
            USDPoint3D(x: minimum.x, y: minimum.y, z: minimum.z),
            USDPoint3D(x: maximum.x, y: minimum.y, z: minimum.z),
            USDPoint3D(x: minimum.x, y: maximum.y, z: minimum.z),
            USDPoint3D(x: minimum.x, y: minimum.y, z: maximum.z),
            USDPoint3D(x: maximum.x, y: maximum.y, z: minimum.z),
            USDPoint3D(x: maximum.x, y: minimum.y, z: maximum.z),
            USDPoint3D(x: minimum.x, y: maximum.y, z: maximum.z),
            USDPoint3D(x: maximum.x, y: maximum.y, z: maximum.z),
        ]
        let transformedCorners = try corners.map { try transform.transform($0) }
        let xs = transformedCorners.map(\.x)
        let ys = transformedCorners.map(\.y)
        let zs = transformedCorners.map(\.z)
        guard let minX = xs.min(),
              let minY = ys.min(),
              let minZ = zs.min(),
              let maxX = xs.max(),
              let maxY = ys.max(),
              let maxZ = zs.max() else {
            return nil
        }
        return [
            USDPoint3D(x: minX, y: minY, z: minZ),
            USDPoint3D(x: maxX, y: maxY, z: maxZ),
        ]
    }

    private func worldTransform(
        forPrimPath primPath: String,
        context: inout USDCTransformContext,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCMatrix4x4 {
        if let cached = context.worldTransforms[primPath] {
            return cached
        }
        var transform = USDCMatrix4x4.identity
        var resetsParentStack = false
        if let record = context.specsByPath[primPath], record.specType == .prim {
            let localTransform = try localTransform(
                forPrimPath: primPath,
                context: &context,
                valueDecoder: valueDecoder
            )
            transform = localTransform.matrix
            resetsParentStack = localTransform.resetsParentStack
        }
        if !resetsParentStack, let parentPath = parentPrimPath(from: primPath), parentPath != "/" {
            transform = try transform.concatenating(
                worldTransform(forPrimPath: parentPath, context: &context, valueDecoder: valueDecoder)
            )
        }
        context.worldTransforms[primPath] = transform
        return transform
    }

    private func localTransform(
        forPrimPath primPath: String,
        context: inout USDCTransformContext,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCLocalTransform {
        if let cached = context.localTransforms[primPath] {
            return cached
        }
        let computed = try computeLocalTransform(
            forPrimPath: primPath,
            attributeRecords: context.attributes(forPrimPath: primPath),
            valueDecoder: valueDecoder
        )
        context.localTransforms[primPath] = computed
        return computed
    }

    private func computeLocalTransform(
        forPrimPath primPath: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCLocalTransform {
        guard let xformOpOrderRep = attributeRecords["xformOpOrder"]?.fields["default"] else {
            return USDCLocalTransform(matrix: .identity, resetsParentStack: false)
        }
        let xformOpOrder = try valueDecoder.readTokenArray(xformOpOrderRep)
        var transform = USDCMatrix4x4.identity
        var resetsParentStack = false
        for opName in xformOpOrder.reversed() {
            if opName == "!resetXformStack!" {
                resetsParentStack = true
                break
            }
            let orderedOp = orderedXformOperationName(from: opName)
            guard let opRecord = attributeRecords[orderedOp.attributeName] else {
                continue
            }
            let opTransform = try self.transform(
                forXformOp: orderedOp.attributeName,
                record: opRecord,
                valueDecoder: valueDecoder
            )
            let effectiveTransform = orderedOp.isInverted ? try opTransform.inverted() : opTransform
            transform = try transform.concatenating(effectiveTransform)
        }
        return USDCLocalTransform(matrix: transform, resetsParentStack: resetsParentStack)
    }

    private func orderedXformOperationName(from opName: String) -> (attributeName: String, isInverted: Bool) {
        let prefix = "!invert!"
        guard opName.hasPrefix(prefix) else {
            return (opName, false)
        }
        var attributeName = String(opName.dropFirst(prefix.count))
        if attributeName.hasPrefix(":") {
            attributeName.removeFirst()
        }
        return (attributeName, true)
    }

    private func transform(
        forXformOp opName: String,
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCMatrix4x4 {
        guard let operationType = xformOperationType(from: opName) else {
            throw USDError.invalidData("USDC xform op \(opName) is malformed.")
        }
        switch operationType {
        case "translate":
            return .translation(try requiredVector3Value(forXformOp: opName, record: record, valueDecoder: valueDecoder))
        case "translateX":
            return .translation(USDCVector3D(
                x: try requiredDoubleValue(forXformOp: opName, record: record, valueDecoder: valueDecoder),
                y: 0,
                z: 0
            ))
        case "translateY":
            return .translation(USDCVector3D(
                x: 0,
                y: try requiredDoubleValue(forXformOp: opName, record: record, valueDecoder: valueDecoder),
                z: 0
            ))
        case "translateZ":
            return .translation(USDCVector3D(
                x: 0,
                y: 0,
                z: try requiredDoubleValue(forXformOp: opName, record: record, valueDecoder: valueDecoder)
            ))
        case "scale":
            return .scale(try requiredVector3Value(forXformOp: opName, record: record, valueDecoder: valueDecoder))
        case "scaleX":
            return .scale(USDCVector3D(
                x: try requiredDoubleValue(forXformOp: opName, record: record, valueDecoder: valueDecoder),
                y: 1,
                z: 1
            ))
        case "scaleY":
            return .scale(USDCVector3D(
                x: 1,
                y: try requiredDoubleValue(forXformOp: opName, record: record, valueDecoder: valueDecoder),
                z: 1
            ))
        case "scaleZ":
            return .scale(USDCVector3D(
                x: 1,
                y: 1,
                z: try requiredDoubleValue(forXformOp: opName, record: record, valueDecoder: valueDecoder)
            ))
        case "rotateX":
            return try .rotationX(angleInDegrees: requiredDoubleValue(
                forXformOp: opName,
                record: record,
                valueDecoder: valueDecoder
            ))
        case "rotateY":
            return try .rotationY(angleInDegrees: requiredDoubleValue(
                forXformOp: opName,
                record: record,
                valueDecoder: valueDecoder
            ))
        case "rotateZ":
            return try .rotationZ(angleInDegrees: requiredDoubleValue(
                forXformOp: opName,
                record: record,
                valueDecoder: valueDecoder
            ))
        case "rotateXYZ", "rotateXZY", "rotateYXZ", "rotateYZX", "rotateZXY", "rotateZYX":
            let order = String(operationType.dropFirst("rotate".count))
            return try .eulerRotation(
                order: order,
                anglesInDegrees: requiredVector3Value(forXformOp: opName, record: record, valueDecoder: valueDecoder)
            )
        case "orient":
            let defaultValue = try requiredDiscreteValueRep(
                forXformOp: opName,
                operationType: operationType,
                record: record,
                valueDecoder: valueDecoder
            )
            return try valueDecoder.readQuaternion(defaultValue).rotationMatrix()
        case "transform":
            let defaultValue = try requiredDiscreteValueRep(
                forXformOp: opName,
                operationType: operationType,
                record: record,
                valueDecoder: valueDecoder
            )
            return try valueDecoder.readMatrix4x4(defaultValue)
        default:
            throw USDError.unsupportedFeature("USDC xform op \(operationType) is not supported yet.")
        }
    }

    private func requiredVector3Value(
        forXformOp opName: String,
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCVector3D {
        if let timeSamples = record.fields["timeSamples"] {
            switch try valueDecoder.readVector3TimeSample(
                timeSamples,
                at: options.timeCode,
                interpolation: options.timeSampleInterpolation
            ) {
            case .value(let value):
                return value
            case .blocked:
                throw USDError.invalidData("USDC xform op \(opName) is blocked at the requested time.")
            case .unresolved:
                break
            }
        }
        let valueRep = try requiredFallbackValueRep(forXformOp: opName, record: record, valueDecoder: valueDecoder)
        return try valueDecoder.readVector3(valueRep)
    }

    private func requiredDoubleValue(
        forXformOp opName: String,
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> Double {
        if let timeSamples = record.fields["timeSamples"] {
            switch try valueDecoder.readDoubleTimeSample(
                timeSamples,
                at: options.timeCode,
                interpolation: options.timeSampleInterpolation
            ) {
            case .value(let value):
                return value
            case .blocked:
                throw USDError.invalidData("USDC xform op \(opName) is blocked at the requested time.")
            case .unresolved:
                break
            }
        }
        let valueRep = try requiredFallbackValueRep(forXformOp: opName, record: record, valueDecoder: valueDecoder)
        return try valueDecoder.readDouble(valueRep)
    }

    private func requiredValueRep(
        forXformOp opName: String,
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCCrateValueRep {
        guard let valueRep = try resolvedValueRep(record: record, valueDecoder: valueDecoder) else {
            throw USDError.invalidData("USDC xform op \(opName) has no default value.")
        }
        return valueRep
    }

    private func requiredDiscreteValueRep(
        forXformOp opName: String,
        operationType: String,
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCCrateValueRep {
        if record.fields["timeSamples"] != nil,
           options.timeCode != nil,
           options.timeSampleInterpolation == .linear {
            throw USDError.unsupportedFeature(
                "USDC xform op \(operationType) timeSamples do not support linear interpolation yet."
            )
        }
        return try requiredValueRep(forXformOp: opName, record: record, valueDecoder: valueDecoder)
    }

    private func requiredFallbackValueRep(
        forXformOp opName: String,
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCCrateValueRep {
        guard let valueRep = try fallbackValueRep(record: record, valueDecoder: valueDecoder) else {
            throw USDError.invalidData("USDC xform op \(opName) has no default value.")
        }
        return valueRep
    }

    private func fallbackValueRep(
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCCrateValueRep? {
        if let defaultValue = record.fields["default"], !valueDecoder.isBlockedValue(defaultValue) {
            return defaultValue
        }
        if let timeSamples = record.fields["timeSamples"] {
            return try valueDecoder.readFirstUnblockedTimeSampleValueRep(timeSamples)
        }
        return nil
    }

    private func xformOperationType(from opName: String) -> String? {
        let prefix = "xformOp:"
        guard opName.hasPrefix(prefix) else {
            return nil
        }
        let suffixStart = opName.index(opName.startIndex, offsetBy: prefix.count)
        return opName[suffixStart...].split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    /// Shared per-read lookup state: a prim-to-attributes index built in one
    /// pass over the specs, plus memoized local and world transforms so
    /// ancestor chains are never recomputed per prim.
    private struct USDCTransformContext {
        let specsByPath: [String: USDCSpecRecord]
        var localTransforms: [String: USDCLocalTransform] = [:]
        var worldTransforms: [String: USDCMatrix4x4] = [:]
        private let attributesByPrimPath: [String: [String: USDCSpecRecord]]

        init(specsByPath: [String: USDCSpecRecord]) {
            self.specsByPath = specsByPath
            var index: [String: [String: USDCSpecRecord]] = [:]
            for (path, record) in specsByPath where record.specType == .attribute {
                guard let lastSlash = path.lastIndex(of: "/"),
                      let dotIndex = path[lastSlash...].firstIndex(of: ".") else {
                    continue
                }
                let primPath = String(path[..<dotIndex])
                let name = String(path[path.index(after: dotIndex)...])
                guard !name.contains("/"), !name.contains(".") else {
                    continue
                }
                index[primPath, default: [:]][name] = record
            }
            attributesByPrimPath = index
        }

        func attributes(forPrimPath primPath: String) -> [String: USDCSpecRecord] {
            attributesByPrimPath[primPath] ?? [:]
        }
    }

    private func requiredPointArray(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [USDPoint3D] {
        guard
            let record = attributeRecords[name],
            let points = try resolvedPointArray(record: record, valueDecoder: valueDecoder)
        else {
            throw USDError.missingRequiredField(name)
        }
        guard !points.isEmpty else {
            throw USDError.invalidData("USDC Mesh \(name) contains no points.")
        }
        return points
    }

    private func optionalPointArray(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [USDPoint3D]? {
        guard
            let record = attributeRecords[name],
            let points = try resolvedPointArray(record: record, valueDecoder: valueDecoder)
        else {
            return nil
        }
        return points
    }

    private func resolvedPointArray(
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [USDPoint3D]? {
        if let timeSamples = record.fields["timeSamples"] {
            switch try valueDecoder.readPointTimeSampleArray(
                timeSamples,
                at: options.timeCode,
                interpolation: options.timeSampleInterpolation
            ) {
            case .value(let points):
                return points
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let defaultValue = try resolvedValueRep(record: record, valueDecoder: valueDecoder) else {
            return nil
        }
        return try valueDecoder.readPointArray(defaultValue)
    }

    private func optionalPoint2Array(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [USDPoint2D]? {
        guard let record = attributeRecords[name] else {
            return nil
        }
        if let timeSamples = record.fields["timeSamples"] {
            switch try valueDecoder.readPoint2TimeSampleArray(
                timeSamples,
                at: options.timeCode,
                interpolation: options.timeSampleInterpolation
            ) {
            case .value(let values):
                return values
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let valueRep = try fallbackValueRep(record: record, valueDecoder: valueDecoder) else {
            return nil
        }
        return try valueDecoder.readPoint2Array(valueRep)
    }

    private func requiredIntArray(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [Int] {
        guard
            let record = attributeRecords[name],
            let valueRep = try resolvedIntArrayValueRep(record: record, valueDecoder: valueDecoder)
        else {
            throw USDError.missingRequiredField(name)
        }
        let values = try valueDecoder.readIntArray(valueRep)
        guard !values.isEmpty else {
            throw USDError.invalidData("USDC Mesh \(name) is empty.")
        }
        return values
    }

    private func optionalIntArray(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [Int]? {
        guard
            let record = attributeRecords[name],
            let valueRep = try resolvedIntArrayValueRep(record: record, valueDecoder: valueDecoder)
        else {
            return nil
        }
        return try valueDecoder.readIntArray(valueRep)
    }

    private func resolvedIntArrayValueRep(
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCCrateValueRep? {
        if let timeSamples = record.fields["timeSamples"], options.timeCode != nil {
            return try valueDecoder.readTimeSampleValueRep(timeSamples, at: options.timeCode)
        }
        return try resolvedValueRep(record: record, valueDecoder: valueDecoder)
    }

    private func optionalDoubleArray(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [Double]? {
        guard let record = attributeRecords[name] else {
            return nil
        }
        if let timeSamples = record.fields["timeSamples"] {
            switch try valueDecoder.readDoubleTimeSampleArray(
                timeSamples,
                at: options.timeCode,
                interpolation: options.timeSampleInterpolation
            ) {
            case .value(let values):
                return values
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let valueRep = try fallbackValueRep(record: record, valueDecoder: valueDecoder) else {
            return nil
        }
        return try valueDecoder.readDoubleArray(valueRep)
    }

    private func optionalTextureCoordinates(
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDTextureCoordinatePrimvar? {
        guard let values = try optionalPoint2Array(
            named: "primvars:st",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        ) else {
            return nil
        }
        let indices = try optionalIntArray(
            named: "primvars:st:indices",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        )
        let interpolation = try optionalMetadataString(
            named: "interpolation",
            record: attributeRecords["primvars:st"],
            valueDecoder: valueDecoder
        )
        return USDTextureCoordinatePrimvar(values: values, indices: indices, interpolation: interpolation)
    }

    private func optionalDisplayColor(
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDDisplayColorPrimvar? {
        guard let values = try optionalPointArray(
            named: "primvars:displayColor",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        ) else {
            return nil
        }
        let colors = values.map { USDColorRGB(r: $0.x, g: $0.y, b: $0.z) }
        let indices = try optionalIntArray(
            named: "primvars:displayColor:indices",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        )
        let interpolation = try optionalMetadataString(
            named: "interpolation",
            record: attributeRecords["primvars:displayColor"],
            valueDecoder: valueDecoder
        )
        return USDDisplayColorPrimvar(values: colors, indices: indices, interpolation: interpolation)
    }

    private func optionalDisplayOpacity(
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDDisplayOpacityPrimvar? {
        guard let values = try optionalDoubleArray(
            named: "primvars:displayOpacity",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        ) else {
            return nil
        }
        let indices = try optionalIntArray(
            named: "primvars:displayOpacity:indices",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        )
        let interpolation = try optionalMetadataString(
            named: "interpolation",
            record: attributeRecords["primvars:displayOpacity"],
            valueDecoder: valueDecoder
        )
        return USDDisplayOpacityPrimvar(values: values, indices: indices, interpolation: interpolation)
    }

    private func optionalString(
        named name: String,
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> String? {
        guard
            let record = attributeRecords[name],
            let defaultValue = try resolvedValueRep(record: record, valueDecoder: valueDecoder)
        else {
            return nil
        }
        return try valueDecoder.readStringLike(defaultValue)
    }

    private func optionalOrientation(
        attributeRecords: [String: USDCSpecRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDOrientation? {
        guard let value = try optionalString(
            named: "orientation",
            attributeRecords: attributeRecords,
            valueDecoder: valueDecoder
        ) else {
            return nil
        }
        guard let orientation = USDOrientation(rawValue: value) else {
            throw USDError.invalidData("Unsupported USDC orientation \(value).")
        }
        return orientation
    }

    private func optionalMetadataString(
        named name: String,
        record: USDCSpecRecord?,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> String? {
        guard let valueRep = record?.fields[name] else {
            return nil
        }
        guard !valueDecoder.isBlockedValue(valueRep) else {
            return nil
        }
        return try valueDecoder.readStringLike(valueRep)
    }

    private func resolvedValueRep(
        record: USDCSpecRecord,
        valueDecoder: USDCCrateValueDecoder
    ) throws -> USDCCrateValueRep? {
        if let timeSamples = record.fields["timeSamples"], options.timeCode != nil {
            return try valueDecoder.readTimeSampleValueRep(timeSamples, at: options.timeCode)
        }
        if let defaultValue = record.fields["default"] {
            if !valueDecoder.isBlockedValue(defaultValue) {
                return defaultValue
            }
        }
        if let timeSamples = record.fields["timeSamples"] {
            return try valueDecoder.readTimeSampleValueRep(timeSamples, at: options.timeCode)
        }
        return nil
    }

    private func primName(from path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else {
            return nil
        }
        return String(path[path.index(after: slash)...])
    }

    private func parentPrimPath(from path: String) -> String? {
        guard path != "/" else {
            return nil
        }
        guard let slash = path.lastIndex(of: "/") else {
            return nil
        }
        if slash == path.startIndex {
            return "/"
        }
        return String(path[..<slash])
    }

    private func isDefSpecifier(_ valueRep: USDCCrateValueRep) throws -> Bool {
        guard valueRep.type == .specifier, valueRep.isInlined, !valueRep.isArray else {
            throw USDError.invalidData("USDC specifier field is malformed.")
        }
        return valueRep.payload == 0
    }
}

private struct USDCSpecRecord {
    var specType: USDCCrateSpecType
    var fields: [String: USDCCrateValueRep]
}

private struct USDCLocalTransform {
    var matrix: USDCMatrix4x4
    var resetsParentStack: Bool
}
