import OpenUSD

struct USDCLayerReader {
    private let crate: USDCCrateFile
    private let sections: USDCCrateStructuralSections

    init(crate: USDCCrateFile, sections: USDCCrateStructuralSections) {
        self.crate = crate
        self.sections = sections
    }

    func readLayer() throws -> USDCLayer {
        let valueDecoder = USDCCrateValueDecoder(
            crate: crate,
            tokens: sections.tokens,
            strings: sections.strings,
            paths: sections.paths
        )
        let records = try buildLayerRecords(
            specs: sections.specs,
            paths: sections.paths,
            fields: sections.fields,
            fieldSetIndexes: sections.fieldSetIndexes,
            tokens: sections.tokens,
            valueDecoder: valueDecoder
        )
        try USDCPrimChildrenValidator.validate(
            records.map {
                USDCPrimChildrenValidationRecord(
                    path: $0.path,
                    specType: $0.specType,
                    fields: $0.fields
                )
            },
            valueDecoder: valueDecoder
        )

        guard let rootRecord = records.first(where: { $0.path == "/" }) else {
            throw USDError.invalidData("USDC layer is missing the pseudo-root spec.")
        }
        let rootFields = rootRecord.fields
        let defaultPrim = try rootFields["defaultPrim"].map { try valueDecoder.readStringLike($0) }
        let metersPerUnit = try rootFields["metersPerUnit"].map { try valueDecoder.readDouble($0) }
        let upAxisToken = try rootFields["upAxis"].map { try valueDecoder.readStringLike($0) }
        let upAxis: USDUpAxis?
        if let upAxisToken {
            guard let parsed = USDUpAxis(rawValue: upAxisToken) else {
                throw USDError.invalidData("Unsupported USDC upAxis \(upAxisToken).")
            }
            upAxis = parsed
        } else {
            upAxis = nil
        }

        let layerSpecs = try records.map { record in
            USDCLayerSpec(
                path: record.path,
                specType: try record.specType.usdSpecType(),
                specifier: record.specifier,
                typeName: record.typeName,
                fieldNames: record.fields.keys.sorted(),
                fields: try layerFieldValues(from: record.fields, valueDecoder: valueDecoder)
            )
        }
        return USDCLayer(
            defaultPrim: defaultPrim,
            metersPerUnit: metersPerUnit,
            upAxis: upAxis,
            specs: layerSpecs
        )
    }

    private func buildLayerRecords(
        specs: [USDCCrateSpec],
        paths: [String],
        fields: [USDCCrateField],
        fieldSetIndexes: [UInt32],
        tokens: [String],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [USDCLayerRecord] {
        try specs.sorted { lhs, rhs in
            lhs.pathIndex < rhs.pathIndex
        }.map { spec in
            guard spec.pathIndex < UInt32(paths.count) else {
                throw USDError.invalidData("USDC spec references a path outside PATHS.")
            }
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
            let specType = try spec.specType.usdSpecType()
            let authoredTypeName = try fieldReps["typeName"].map { try valueDecoder.readStringLike($0) }
            return USDCLayerRecord(
                path: path,
                specType: spec.specType,
                fields: fieldReps,
                specifier: try specifier(from: fieldReps["specifier"]),
                typeName: try authoredTypeName ?? inferredTypeName(
                    for: path,
                    specType: specType,
                    fields: fieldReps,
                    valueDecoder: valueDecoder
                )
            )
        }
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

    private func specifier(from valueRep: USDCCrateValueRep?) throws -> SdfSpecifier? {
        guard let valueRep else {
            return nil
        }
        guard valueRep.type == .specifier, valueRep.isInlined, !valueRep.isArray else {
            throw USDError.invalidData("USDC specifier field is malformed.")
        }
        return USDCPrimSpecifier(payload: valueRep.payload).layerSpecifier
    }

    private func layerFieldValues(
        from fields: [String: USDCCrateValueRep],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> [String: USDCLayerFieldValue] {
        var values: [String: USDCLayerFieldValue] = [:]
        for (name, valueRep) in fields {
            values[name] = try valueDecoder.readLayerFieldValue(valueRep)
        }
        return values
    }

    private func inferredTypeName(
        for path: String,
        specType: SdfSpecType,
        fields: [String: USDCCrateValueRep],
        valueDecoder: USDCCrateValueDecoder
    ) throws -> String? {
        guard specType == .attribute else {
            return nil
        }
        if let defaultValue = fields["default"],
           !valueDecoder.isBlockedValue(defaultValue) {
            return inferredTypeName(for: path, valueRep: defaultValue)
        }
        if let timeSamples = fields["timeSamples"],
           let sampledValue = try valueDecoder.readFirstUnblockedTimeSampleValueRep(timeSamples) {
            return inferredTypeName(for: path, valueRep: sampledValue)
        }
        return nil
    }

    private func inferredTypeName(for path: String, valueRep: USDCCrateValueRep) -> String? {
        guard let type = valueRep.type else {
            return nil
        }
        let baseName: String
        switch type {
        case .bool:
            baseName = "bool"
        case .uChar:
            baseName = "uchar"
        case .uInt:
            baseName = "uint"
        case .int64:
            baseName = "int64"
        case .uInt64:
            baseName = "uint64"
        case .token:
            baseName = "token"
        case .string:
            baseName = "string"
        case .assetPath:
            baseName = "asset"
        case .float:
            baseName = "float"
        case .double:
            baseName = "double"
        case .int:
            baseName = "int"
        case .timeCode:
            baseName = "timecode"
        case .vec2d:
            baseName = "double2"
        case .vec2f:
            baseName = "float2"
        case .vec3d:
            baseName = vector3TypeName(for: path, precision: "d")
        case .vec3f:
            baseName = vector3TypeName(for: path, precision: "f")
        default:
            return nil
        }
        return valueRep.isArray ? "\(baseName)[]" : baseName
    }

    private func vector3TypeName(for path: String, precision: String) -> String {
        let propertyName = path.split(separator: ".").last.map(String.init) ?? path
        if propertyName == "points" || propertyName == "extent" {
            return "point3\(precision)"
        }
        if propertyName == "normals" {
            return "normal3\(precision)"
        }
        if propertyName == "primvars:displayColor" {
            return "color3\(precision)"
        }
        if propertyName.hasPrefix("xformOp:") {
            return precision == "d" ? "double3" : "float3"
        }
        return "vector3\(precision)"
    }
}

private struct USDCLayerRecord {
    var path: String
    var specType: USDCCrateSpecType
    var fields: [String: USDCCrateValueRep]
    var specifier: SdfSpecifier?
    var typeName: String?
}

private extension USDCCrateSpecType {
    func usdSpecType() throws -> SdfSpecType {
        switch self {
        case .attribute:
            .attribute
        case .connection:
            .connection
        case .expression:
            .expression
        case .mapper:
            .mapper
        case .mapperArgument:
            .mapperArgument
        case .prim:
            .prim
        case .pseudoRoot:
            .pseudoRoot
        case .relationship:
            .relationship
        case .relationshipTarget:
            .relationshipTarget
        case .variant:
            .variant
        case .variantSet:
            .variantSet
        case .unknown:
            throw USDError.invalidData("USDC spec type is not concrete.")
        }
    }
}
