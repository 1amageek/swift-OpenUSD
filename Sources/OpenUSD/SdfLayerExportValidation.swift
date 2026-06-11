import Foundation

/// Summarizes which variants and variant sets contain structured child
/// specs. Built in a single pass so that per-spec export validation does
/// not rescan the whole spec array.
private struct SdfVariantStructureIndex {
    let variantPathsWithStructuredContent: Set<SdfPath>
    let variantSetPathsWithStructuredVariants: Set<SdfPath>

    init(specs: [SdfSpec]) {
        var contentParentPaths: Set<SdfPath> = []
        var structuredVariantSetPaths: Set<SdfPath> = []
        for spec in specs {
            switch spec.specType {
            case .prim, .variantSet:
                if let parentPath = spec.path.parentPath {
                    contentParentPaths.insert(parentPath)
                }
            case .attribute, .relationship:
                if let primPath = spec.path.primPath {
                    contentParentPaths.insert(primPath)
                }
            case .connection, .relationshipTarget:
                if let primPath = spec.path.propertyPath?.primPath {
                    contentParentPaths.insert(primPath)
                }
            case .variant:
                if let variantSetPath = spec.path.variantSetPath {
                    structuredVariantSetPaths.insert(variantSetPath)
                }
            case .pseudoRoot, .expression, .mapper, .mapperArgument:
                continue
            }
        }
        self.variantPathsWithStructuredContent = contentParentPaths
        self.variantSetPathsWithStructuredVariants = structuredVariantSetPaths
    }
}

extension SdfLayer {
    internal func validateUSDAExportSupport() throws {
        try validate()
        let variantStructure = SdfVariantStructureIndex(specs: specs)
        for spec in specs {
            try spec.validateUSDAExportSupport()
            try validateStringDictionaryMetadataFieldsForUSDAExport(in: spec)
            try validateMetadataListOperationFieldsForUSDAExport(in: spec)
            try validatePathListFieldsForUSDAExport(in: spec)
            try validateAssetReferenceListFieldsForUSDAExport(in: spec)
            try validateVariantAuthoringSupport(in: spec, variantStructure: variantStructure)
            try validatePropertyTargetSpecExportSupport(in: spec)
        }
    }

    private func validatePathListFieldsForUSDAExport(in spec: SdfSpec) throws {
        for (fieldName, fieldValue) in spec.fields {
            guard case .pathListOperation = fieldValue else {
                continue
            }
            let supported =
                (spec.specType == .prim && fieldName == "properties")
                || (spec.specType == .prim && (fieldName == "inheritPaths" || fieldName == "specializes"))
                || (spec.specType == .variant && fieldName == "properties")
                || (spec.specType == .attribute && fieldName == "connectionPaths")
                || (spec.specType == .relationship && fieldName == "targetPaths")
            guard supported else {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export path list field \(fieldName) at \(spec.path.rawValue) to USDA without data loss."
                )
            }
        }
    }

    private func validateMetadataListOperationFieldsForUSDAExport(in spec: SdfSpec) throws {
        for (fieldName, fieldValue) in spec.fields {
            let supported: Bool
            switch fieldValue {
            case .tokenListOperation:
                supported = spec.specType == .prim && fieldName == "apiSchemas"
            case .stringListOperation(let operation):
                supported = spec.specType == .prim && fieldName == "variantSetNames"
                if supported {
                    try validateVariantSetNames(operation, path: spec.path)
                }
            default:
                continue
            }
            guard supported else {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export metadata list operation field \(fieldName) at \(spec.path.rawValue) to USDA without data loss."
                )
            }
        }
    }

    private func validateVariantSetNames(_ operation: SdfListOperation<String>, path: SdfPath) throws {
        for name in operation.explicitItems
            + operation.addedItems
            + operation.prependedItems
            + operation.appendedItems
            + operation.deletedItems
            + operation.orderedItems {
            guard isValidUSDIdentifier(name) else {
                throw USDError.invalidData(
                    "SdfLayer variantSetNames metadata at \(path.rawValue) contains invalid variant set name \(name)."
                )
            }
        }
    }

    private func isValidUSDIdentifier(_ value: String) -> Bool {
        guard let firstScalar = value.unicodeScalars.first else {
            return false
        }
        guard firstScalar.value == 0x5f || firstScalar.properties.isXIDStart else {
            return false
        }
        for scalar in value.unicodeScalars.dropFirst() {
            guard scalar.properties.isXIDContinue else {
                return false
            }
        }
        return true
    }

    private func validateStringDictionaryMetadataFieldsForUSDAExport(in spec: SdfSpec) throws {
        for (fieldName, fieldValue) in spec.fields {
            guard fieldName == "prefixSubstitutions" || fieldName == "suffixSubstitutions" else {
                continue
            }
            guard case .dictionary(let values) = fieldValue else {
                continue
            }
            for (key, value) in values {
                guard !key.isEmpty else {
                    throw USDError.invalidData(
                        "SdfLayer \(fieldName) metadata at \(spec.path.rawValue) contains an empty substitution key."
                    )
                }
                guard case .string = value else {
                    throw USDError.invalidData(
                        "SdfLayer \(fieldName) metadata at \(spec.path.rawValue) must contain only string substitution values."
                    )
                }
            }
        }
    }

    private func validateAssetReferenceListFieldsForUSDAExport(in spec: SdfSpec) throws {
        for (fieldName, fieldValue) in spec.fields {
            let supported: Bool
            switch fieldValue {
            case .referenceListOperation:
                supported = spec.specType == .prim && fieldName == "references"
            case .payloadListOperation,
                 .payload:
                supported = spec.specType == .prim && fieldName == "payload"
            default:
                continue
            }
            guard supported else {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export asset reference field \(fieldName) at \(spec.path.rawValue) to USDA without data loss."
                )
            }
        }
    }

    private func validateVariantAuthoringSupport(
        in spec: SdfSpec,
        variantStructure: SdfVariantStructureIndex
    ) throws {
        guard spec.path.rawValue.contains("{") else {
            return
        }
        switch spec.specType {
        case .variantSet:
            let supportedNames = Set(["name", "body"])
            let unsupportedNames = spec.listFields().filter { !supportedNames.contains($0) }
            guard unsupportedNames.isEmpty else {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export authored fields \(unsupportedNames.sorted().joined(separator: ", ")) on variant set \(spec.path.rawValue)."
                )
            }
            if spec.fields["body"]?.authoredText?.isEmpty == false,
               variantStructure.variantSetPathsWithStructuredVariants.contains(spec.path) {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export variant set \(spec.path.rawValue) because it mixes raw body text with structured variant specs."
                )
            }
            return
        case .variant:
            let supportedNames = Set(["name", "body", "properties"])
            let unsupportedNames = spec.listFields().filter { !supportedNames.contains($0) }
            guard unsupportedNames.isEmpty else {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export authored fields \(unsupportedNames.sorted().joined(separator: ", ")) on variant \(spec.path.rawValue)."
                )
            }
            if spec.fields["body"]?.authoredText?.isEmpty == false,
               spec.fields["properties"] != nil
                || variantStructure.variantPathsWithStructuredContent.contains(spec.path) {
                throw USDError.unsupportedFeature(
                    "SdfLayer cannot export variant \(spec.path.rawValue) because it mixes raw body text with structured child specs."
                )
            }
            return
        default:
            return
        }
    }

    private func validatePropertyTargetSpecExportSupport(in spec: SdfSpec) throws {
        guard spec.specType == .connection || spec.specType == .relationshipTarget else {
            return
        }
        guard spec.fields.isEmpty else {
            throw USDError.unsupportedFeature(
                "SdfLayer cannot export authored fields on target spec \(spec.path.rawValue) to USDA without data loss."
            )
        }
    }

}
