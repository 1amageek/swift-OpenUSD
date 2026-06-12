import Foundation

public indirect enum SdfFieldValue: Sendable, Equatable, Hashable {
    case unmaterializedValue
    case authored(String)
    case timeSamples([SdfTimeSample])
    case bool(Bool)
    case boolArray([Bool])
    case token(String)
    case tokenArray([String])
    case tokenVector([String])
    case string(String)
    case stringVector([String])
    case assetPath(String)
    case dictionary([String: SdfFieldValue])
    case path(SdfPath)
    case pathVector([SdfPath])
    case variantSelectionMap([String: String])
    case tokenListOperation(SdfListOperation<String>)
    case stringListOperation(SdfListOperation<String>)
    case pathListOperation(SdfListOperation<SdfPath>)
    case referenceListOperation(SdfListOperation<SdfReference>)
    case payloadListOperation(SdfListOperation<SdfPayload>)
    case payload(SdfPayload)
    case int(Int)
    case double(Double)
    case doubleArray([Double])
    case doubleVector([Double])
    case intArray([Int])
    case timeCode(Double)
    case timeCodeArray([Double])
    case point2(USDPoint2D)
    case point2Array([USDPoint2D])
    case point3(USDPoint3D)
    case point3Array([USDPoint3D])
    case layerOffsetVector([SdfLayerOffset])
    case permission(SdfPermission)
    case variability(SdfVariability)
    case specifier(SdfSpecifier)

    public init(layerFieldValue: USDLayerFieldValue) throws {
        switch layerFieldValue {
        case .unmaterializedValue:
            self = .unmaterializedValue
        case .authored(let value):
            self = .authored(value)
        case .timeSamples(let samples):
            self = .timeSamples(samples)
        case .dictionary(let values):
            self = .dictionary(values)
        case .tokenListOperation(let operation):
            self = .tokenListOperation(operation)
        case .stringListOperation(let operation):
            self = .stringListOperation(operation)
        case .pathListOperation(let operation):
            self = .pathListOperation(try operation.mapItems(SdfPath.init))
        case .referenceListOperation(let operation):
            self = .referenceListOperation(operation)
        case .payloadListOperation(let operation):
            self = .payloadListOperation(operation)
        case .payload(let payload):
            self = .payload(payload)
        }
    }

    public var authoredText: String? {
        guard case .authored(let text) = self else {
            return nil
        }
        return text
    }

    public var pathListOperation: SdfListOperation<SdfPath>? {
        guard case .pathListOperation(let operation) = self else {
            return nil
        }
        return operation
    }

    /// Converts this typed field value to the string-based `USDLayerFieldValue` model.
    ///
    /// This conversion is lossy for most typed cases: every case that does not
    /// have a direct `USDLayerFieldValue` counterpart (booleans, tokens,
    /// strings, numbers, paths, asset paths, layer offsets, variant selection
    /// maps, permissions, variabilities, and specifiers) is flattened to
    /// `.authored` USDA source text, which discards the static type
    /// information. Converting back from the authored text requires re-parsing
    /// and cannot distinguish, for example, `.token` from `.string`,
    /// `.double` from `.timeCode`, or `.tokenArray` from `.tokenVector`.
    /// Dictionary and list-operation cases convert without loss.
    public func toUSDLayerFieldValue() -> USDLayerFieldValue {
        switch self {
        case .unmaterializedValue:
            return .unmaterializedValue
        case .authored(let value):
            return .authored(value)
        case .timeSamples(let samples):
            return .timeSamples(samples)
        case .dictionary(let values):
            return .dictionary(values)
        case .pathListOperation(let operation):
            return .pathListOperation(operation.mapItems(\.rawValue))
        case .bool(let value):
            return .authored(value ? "true" : "false")
        case .boolArray(let values):
            return .authored("[\(values.map { $0 ? "true" : "false" }.joined(separator: ", "))]")
        case .token(let value), .string(let value):
            return .authored(Self.quoted(value))
        case .tokenArray(let values), .tokenVector(let values), .stringVector(let values):
            return .authored("[\(values.map(Self.quoted).joined(separator: ", "))]")
        case .assetPath(let value):
            return .authored(Self.assetPathText(value))
        case .path(let value):
            return .authored("<\(value.rawValue)>")
        case .pathVector(let values):
            return .authored("[\(values.map { "<\($0.rawValue)>" }.joined(separator: ", "))]")
        case .variantSelectionMap(let selections):
            return .authored(Self.variantSelectionMapText(selections))
        case .tokenListOperation(let operation):
            return .tokenListOperation(operation)
        case .stringListOperation(let operation):
            return .stringListOperation(operation)
        case .referenceListOperation(let operation):
            return .referenceListOperation(operation)
        case .payloadListOperation(let operation):
            return .payloadListOperation(operation)
        case .payload(let payload):
            return .payload(payload)
        case .int(let value):
            return .authored(String(value))
        case .double(let value), .timeCode(let value):
            return .authored(Self.doubleText(value))
        case .doubleArray(let values), .doubleVector(let values), .timeCodeArray(let values):
            return .authored("[\(values.map(Self.doubleText).joined(separator: ", "))]")
        case .intArray(let values):
            return .authored("[\(values.map(String.init).joined(separator: ", "))]")
        case .point2(let value):
            return .authored("(\(Self.doubleText(value.x)), \(Self.doubleText(value.y)))")
        case .point2Array(let values):
            return .authored("[\(values.map { "(\(Self.doubleText($0.x)), \(Self.doubleText($0.y)))" }.joined(separator: ", "))]")
        case .point3(let value):
            return .authored(Self.point3Text(value))
        case .point3Array(let values):
            return .authored("[\(values.map(Self.point3Text).joined(separator: ", "))]")
        case .layerOffsetVector(let values):
            return .authored("[\(values.map(Self.layerOffsetText).joined(separator: ", "))]")
        case .permission(let value):
            return .authored(value == .privateAccess ? "private" : "public")
        case .variability(let value):
            return .authored(value == .uniform ? "uniform" : "varying")
        case .specifier(let value):
            return .authored(Self.quoted(Self.specifierText(value)))
        }
    }

    /// Encodes a raw string as a double-quoted single-line USDA string literal.
    ///
    /// Escapes backslashes and double quotes, and encodes newline, tab, and
    /// carriage return as `\n`, `\t`, and `\r` so the literal stays on one
    /// line. This is the symmetric counterpart of the escape decoding
    /// performed by `USDAReader` when it parses quoted strings.
    internal static func quoted(_ value: String) -> String {
        var encoded = "\""
        for character in value {
            switch character {
            case "\\":
                encoded += "\\\\"
            case "\"":
                encoded += "\\\""
            case "\n":
                encoded += "\\n"
            case "\t":
                encoded += "\\t"
            case "\r":
                encoded += "\\r"
            default:
                encoded.append(character)
            }
        }
        encoded += "\""
        return encoded
    }

    internal static func usdaDictionaryText(_ values: [String: SdfFieldValue]) throws -> String {
        let lines = try values.keys.sorted().map { key in
            try "    \(usdaDictionaryEntryText(name: key, value: values[key] ?? .unmaterializedValue))"
        }
        guard !lines.isEmpty else {
            return "{}"
        }
        return "{\n\(lines.joined(separator: "\n"))\n}"
    }

    internal static func usdaDictionaryEntryText(name: String, value: SdfFieldValue) throws -> String {
        switch value {
        case .bool(let value):
            return "bool \(usdaDictionaryKeyText(name)) = \(value ? "true" : "false")"
        case .boolArray(let values):
            return "bool[] \(usdaDictionaryKeyText(name)) = [\(values.map { $0 ? "true" : "false" }.joined(separator: ", "))]"
        case .token(let value):
            return "token \(usdaDictionaryKeyText(name)) = \(quoted(value))"
        case .tokenArray(let values), .tokenVector(let values):
            return "token[] \(usdaDictionaryKeyText(name)) = [\(values.map(quoted).joined(separator: ", "))]"
        case .string(let value):
            return "string \(usdaDictionaryKeyText(name)) = \(quoted(value))"
        case .stringVector(let values):
            return "string[] \(usdaDictionaryKeyText(name)) = [\(values.map(quoted).joined(separator: ", "))]"
        case .assetPath(let value):
            return "asset \(usdaDictionaryKeyText(name)) = \(assetPathText(value))"
        case .dictionary(let values):
            return "dictionary \(usdaDictionaryKeyText(name)) = \(try usdaDictionaryText(values))"
        case .int(let value):
            return "int \(usdaDictionaryKeyText(name)) = \(value)"
        case .intArray(let values):
            return "int[] \(usdaDictionaryKeyText(name)) = [\(values.map(String.init).joined(separator: ", "))]"
        case .double(let value):
            return "double \(usdaDictionaryKeyText(name)) = \(doubleText(value))"
        case .doubleArray(let values), .doubleVector(let values):
            return "double[] \(usdaDictionaryKeyText(name)) = [\(values.map(doubleText).joined(separator: ", "))]"
        case .point2(let value):
            return "double2 \(usdaDictionaryKeyText(name)) = \(point2Text(value))"
        case .point2Array(let values):
            return "double2[] \(usdaDictionaryKeyText(name)) = [\(values.map(point2Text).joined(separator: ", "))]"
        case .point3(let value):
            return "double3 \(usdaDictionaryKeyText(name)) = \(point3Text(value))"
        case .point3Array(let values):
            return "double3[] \(usdaDictionaryKeyText(name)) = [\(values.map(point3Text).joined(separator: ", "))]"
        case .timeCode(let value):
            return "timecode \(usdaDictionaryKeyText(name)) = \(doubleText(value))"
        case .timeCodeArray(let values):
            return "timecode[] \(usdaDictionaryKeyText(name)) = [\(values.map(doubleText).joined(separator: ", "))]"
        default:
            throw USDError.unsupportedFeature(
                "USDA cannot export dictionary field \(name) with value \(value) without data loss."
            )
        }
    }

    private static func usdaDictionaryKeyText(_ value: String) -> String {
        isValidUSDAIdentifier(value) ? value : quoted(value)
    }

    private static func isValidUSDAIdentifier(_ value: String) -> Bool {
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

    private static func variantSelectionMapText(_ selections: [String: String]) -> String {
        let lines = selections.keys.sorted().map { key in
            "    string \(key) = \(quoted(selections[key] ?? ""))"
        }
        guard !lines.isEmpty else {
            return "{}"
        }
        return "{\n\(lines.joined(separator: "\n"))\n}"
    }

    private static func assetReferenceText(assetPath: String, primPath: SdfPath?) -> String {
        if let primPath {
            return "\(assetPathText(assetPath))<\(primPath.rawValue)>"
        }
        return assetPathText(assetPath)
    }

    /// Encodes an asset path as a USDA asset literal.
    ///
    /// Paths without `@` use the single-delimiter form `@path@`. Paths that
    /// contain `@` must use the triple-delimiter form `@@@path@@@`, in which
    /// any literal `@@@` run is escaped as `\@@@` per the USDA grammar.
    internal static func assetPathText(_ assetPath: String) -> String {
        guard assetPath.contains("@") else {
            return "@\(assetPath)@"
        }
        return "@@@\(assetPath.replacingOccurrences(of: "@@@", with: "\\@@@"))@@@"
    }

    internal static func layerOffsetSuffix(_ layerOffset: SdfLayerOffset) -> String {
        guard !layerOffset.isIdentity else {
            return ""
        }
        return " (offset = \(doubleText(layerOffset.offset)); scale = \(doubleText(layerOffset.scale)))"
    }

    private static func layerOffsetText(_ layerOffset: SdfLayerOffset) -> String {
        "(\(doubleText(layerOffset.offset)), \(doubleText(layerOffset.scale)))"
    }

    private static func point2Text(_ value: USDPoint2D) -> String {
        "(\(doubleText(value.x)), \(doubleText(value.y)))"
    }

    internal static func point3Text(_ value: USDPoint3D) -> String {
        "(\(doubleText(value.x)), \(doubleText(value.y)), \(doubleText(value.z)))"
    }

    internal static func timeSamplesText(_ samples: [SdfTimeSample]) throws -> String {
        guard !samples.isEmpty else {
            return "{}"
        }
        var seenTimeCodes: Set<Double> = []
        let lines = try samples.map { sample in
            guard sample.timeCode.isFinite else {
                throw USDError.invalidData("SdfFieldValue timeSamples contains a non-finite timeCode.")
            }
            guard seenTimeCodes.insert(sample.timeCode).inserted else {
                throw USDError.invalidData("SdfFieldValue timeSamples contains duplicate timeCode values.")
            }
            let valueText = try sample.value?.usdaValueText() ?? "None"
            return "    \(timeCodeText(sample.timeCode)): \(valueText)"
        }
        return "{\n\(lines.joined(separator: ",\n"))\n}"
    }

    internal func usdaValueText() throws -> String {
        switch self {
        case .unmaterializedValue:
            throw USDError.unsupportedFeature("SdfFieldValue is unmaterialized and cannot be exported to USDA without data loss.")
        case .authored(let value):
            return value
        case .timeSamples(let samples):
            return try Self.timeSamplesText(samples)
        case .bool(let value):
            return value ? "true" : "false"
        case .boolArray(let values):
            return "[\(values.map { $0 ? "true" : "false" }.joined(separator: ", "))]"
        case .token(let value), .string(let value):
            return Self.quoted(value)
        case .tokenArray(let values), .tokenVector(let values), .stringVector(let values):
            return "[\(values.map(Self.quoted).joined(separator: ", "))]"
        case .assetPath(let value):
            return Self.assetPathText(value)
        case .dictionary(let values):
            return try Self.usdaDictionaryText(values)
        case .path(let value):
            return "<\(value.rawValue)>"
        case .pathVector(let values):
            return "[\(values.map { "<\($0.rawValue)>" }.joined(separator: ", "))]"
        case .variantSelectionMap(let values):
            return Self.variantSelectionMapText(values)
        case .tokenListOperation,
             .stringListOperation,
             .pathListOperation,
             .referenceListOperation,
             .payloadListOperation,
             .payload,
             .layerOffsetVector,
             .permission,
             .variability,
             .specifier:
            throw USDError.unsupportedFeature("SdfFieldValue requires statement-style USDA authoring and cannot be used as a bare value.")
        case .int(let value):
            return String(value)
        case .double(let value), .timeCode(let value):
            return Self.doubleText(value)
        case .doubleArray(let values), .doubleVector(let values), .timeCodeArray(let values):
            return "[\(values.map(Self.doubleText).joined(separator: ", "))]"
        case .intArray(let values):
            return "[\(values.map(String.init).joined(separator: ", "))]"
        case .point2(let value):
            return Self.point2Text(value)
        case .point2Array(let values):
            return "[\(values.map(Self.point2Text).joined(separator: ", "))]"
        case .point3(let value):
            return Self.point3Text(value)
        case .point3Array(let values):
            return "[\(values.map(Self.point3Text).joined(separator: ", "))]"
        }
    }

    internal static func specifierText(_ specifier: SdfSpecifier) -> String {
        switch specifier {
        case .def:
            return "def"
        case .over:
            return "over"
        case .class:
            return "class"
        case .unknown(let payload):
            return "unknown(\(payload))"
        }
    }

    internal static func doubleText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    internal static func timeCodeText(_ value: Double) -> String {
        if value.rounded() == value, value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    internal func validateUSDAExportSupport(fieldName: String, path: SdfPath) throws {
        switch self {
        case .unmaterializedValue:
            throw USDError.unsupportedFeature(
                "SdfFieldValue \(fieldName) at \(path.rawValue) is unmaterialized and cannot be exported to USDA without data loss."
            )
        case .dictionary(let values):
            for (childName, childValue) in values {
                try childValue.validateUSDAExportSupport(fieldName: "\(fieldName).\(childName)", path: path)
                try childValue.validateDictionaryEntryUSDAExportSupport(fieldName: "\(fieldName).\(childName)", path: path)
            }
        case .timeSamples(let samples):
            var seenTimeCodes: Set<Double> = []
            for sample in samples {
                try Self.validateFinite(sample.timeCode, fieldName: "\(fieldName).timeCode", path: path)
                guard seenTimeCodes.insert(sample.timeCode).inserted else {
                    throw USDError.invalidData("SdfFieldValue \(fieldName) at \(path.rawValue) contains duplicate timeCode values.")
                }
                try sample.value?.validateUSDAExportSupport(fieldName: "\(fieldName).timeSamples", path: path)
            }
        case .referenceListOperation(let operation):
            try validateListOperation(operation) { reference in
                try Self.validateLayerOffset(reference.layerOffset, fieldName: fieldName, path: path)
                for (customName, customValue) in reference.customData {
                    try customValue.validateUSDAExportSupport(fieldName: "\(fieldName).customData.\(customName)", path: path)
                    try customValue.validateDictionaryEntryUSDAExportSupport(
                        fieldName: "\(fieldName).customData.\(customName)",
                        path: path
                    )
                }
            }
        case .payloadListOperation(let operation):
            try validateListOperation(operation) { payload in
                try Self.validateLayerOffset(payload.layerOffset, fieldName: fieldName, path: path)
            }
        case .payload(let payload):
            try Self.validateLayerOffset(payload.layerOffset, fieldName: fieldName, path: path)
        case .double(let value), .timeCode(let value):
            try Self.validateFinite(value, fieldName: fieldName, path: path)
        case .doubleArray(let values), .doubleVector(let values), .timeCodeArray(let values):
            for value in values {
                try Self.validateFinite(value, fieldName: fieldName, path: path)
            }
        case .point2(let value):
            try Self.validateFinite(value.x, fieldName: fieldName, path: path)
            try Self.validateFinite(value.y, fieldName: fieldName, path: path)
        case .point2Array(let values):
            for value in values {
                try Self.validateFinite(value.x, fieldName: fieldName, path: path)
                try Self.validateFinite(value.y, fieldName: fieldName, path: path)
            }
        case .point3(let value):
            try Self.validateFinite(value.x, fieldName: fieldName, path: path)
            try Self.validateFinite(value.y, fieldName: fieldName, path: path)
            try Self.validateFinite(value.z, fieldName: fieldName, path: path)
        case .point3Array(let values):
            for value in values {
                try Self.validateFinite(value.x, fieldName: fieldName, path: path)
                try Self.validateFinite(value.y, fieldName: fieldName, path: path)
                try Self.validateFinite(value.z, fieldName: fieldName, path: path)
            }
        case .layerOffsetVector(let values):
            for value in values {
                try Self.validateLayerOffset(value, fieldName: fieldName, path: path)
            }
        case .authored,
             .bool,
             .boolArray,
             .token,
             .tokenArray,
             .tokenVector,
             .string,
             .stringVector,
             .assetPath,
             .path,
             .pathVector,
             .variantSelectionMap,
             .tokenListOperation,
             .stringListOperation,
             .pathListOperation,
             .int,
             .intArray,
             .permission,
             .variability,
             .specifier:
            return
        }
    }

    private func validateDictionaryEntryUSDAExportSupport(fieldName: String, path: SdfPath) throws {
        switch self {
        case .authored,
             .unmaterializedValue,
             .timeSamples,
             .path,
             .pathVector,
             .variantSelectionMap,
             .tokenListOperation,
             .stringListOperation,
             .pathListOperation,
             .referenceListOperation,
             .payloadListOperation,
             .payload,
             .layerOffsetVector,
             .permission,
             .variability,
             .specifier:
            throw USDError.unsupportedFeature(
                "SdfFieldValue \(fieldName) at \(path.rawValue) requires statement-style USDA authoring and cannot be exported inside a dictionary without data loss."
            )
        default:
            return
        }
    }

    private func validateListOperation<Item: Sendable & Equatable & Hashable>(
        _ operation: SdfListOperation<Item>,
        validateItem: (Item) throws -> Void
    ) throws {
        for item in operation.explicitItems {
            try validateItem(item)
        }
        for item in operation.addedItems {
            try validateItem(item)
        }
        for item in operation.prependedItems {
            try validateItem(item)
        }
        for item in operation.appendedItems {
            try validateItem(item)
        }
        for item in operation.deletedItems {
            try validateItem(item)
        }
        for item in operation.orderedItems {
            try validateItem(item)
        }
    }

    private static func validateLayerOffset(_ layerOffset: SdfLayerOffset, fieldName: String, path: SdfPath) throws {
        try validateFinite(layerOffset.offset, fieldName: fieldName, path: path)
        try validateFinite(layerOffset.scale, fieldName: fieldName, path: path)
    }

    private static func validateFinite(_ value: Double, fieldName: String, path: SdfPath) throws {
        guard value.isFinite else {
            throw USDError.invalidData(
                "SdfFieldValue \(fieldName) at \(path.rawValue) contains a non-finite floating-point value."
            )
        }
    }
}
