import OpenUSD

enum USDCPrimChildrenValidator {
    static func validate(
        _ records: [USDCPrimChildrenValidationRecord],
        valueDecoder: USDCCrateValueDecoder
    ) throws {
        let primPaths = Set(
            records
                .filter { $0.specType == .pseudoRoot || $0.specType == .prim }
                .map(\.path)
        )

        for record in records {
            guard let valueRep = record.fields["primChildren"] else {
                continue
            }
            guard record.specType == .pseudoRoot || record.specType == .prim else {
                throw USDError.invalidData("USDC primChildren field appears on non-prim spec \(record.path).")
            }
            let fieldValue: USDCLayerFieldValue
            do {
                fieldValue = try valueDecoder.readLayerFieldValue(valueRep)
            } catch {
                throw USDError.invalidData(
                    "USDC primChildren for \(record.path) is invalid: \(errorMessage(from: error))"
                )
            }
            guard case .tokenVector(let childNames) = fieldValue else {
                throw USDError.invalidData("USDC primChildren field is invalid: \(description(of: fieldValue)).")
            }
            try validateChildNames(childNames, parentPath: record.path, primPaths: primPaths)
        }
    }

    private static func description(of value: USDCLayerFieldValue) -> String {
        if case .unmaterializedValue(let unmaterialized) = value {
            return "\(unmaterialized.typeName) value type"
        }
        return String(describing: value)
    }

    private static func validateChildNames(
        _ childNames: [String],
        parentPath: String,
        primPaths: Set<String>
    ) throws {
        var seenChildNames: Set<String> = []
        for childName in childNames {
            guard !childName.isEmpty else {
                throw USDError.invalidData("USDC primChildren for \(parentPath) contains an empty child name.")
            }
            guard !childName.contains("/") else {
                throw USDError.invalidData("USDC primChildren for \(parentPath) contains invalid child name \(childName).")
            }
            guard seenChildNames.insert(childName).inserted else {
                throw USDError.invalidData("USDC primChildren for \(parentPath) contains duplicate child \(childName).")
            }
            let childPath = primPath(parentPath: parentPath, childName: childName)
            guard primPaths.contains(childPath) else {
                throw USDError.invalidData("USDC primChildren for \(parentPath) references missing child \(childName).")
            }
        }
    }

    private static func primPath(parentPath: String, childName: String) -> String {
        if parentPath == "/" {
            return "/\(childName)"
        }
        return "\(parentPath)/\(childName)"
    }

    private static func errorMessage(from error: Error) -> String {
        if let usdError = error as? USDError {
            switch usdError {
            case .invalidData(let message),
                 .missingRequiredField(let message),
                 .unsupportedFeature(let message),
                 .notImplemented(let message):
                return message
            }
        }
        return String(describing: error)
    }
}

struct USDCPrimChildrenValidationRecord {
    var path: String
    var specType: USDCCrateSpecType
    var fields: [String: USDCCrateValueRep]
}
