public struct SdfSpec: Sendable, Equatable, Hashable {
    public var path: SdfPath
    public var specType: SdfSpecType
    public var specifier: SdfSpecifier?
    public var typeName: String?
    public var fieldNames: [String]
    public var fields: [String: SdfFieldValue]

    public init(
        path: SdfPath,
        specType: SdfSpecType,
        specifier: SdfSpecifier? = nil,
        typeName: String? = nil,
        fieldNames: [String] = [],
        fields: [String: SdfFieldValue] = [:]
    ) {
        self.path = path
        self.specType = specType
        self.specifier = specifier
        self.typeName = typeName
        self.fieldNames = fieldNames.isEmpty ? fields.keys.sorted() : fieldNames
        self.fields = fields
    }

    public init(
        path: String,
        specType: SdfSpecType,
        specifier: SdfSpecifier? = nil,
        typeName: String? = nil,
        fieldNames: [String] = [],
        fields: [String: SdfFieldValue] = [:]
    ) throws {
        self.init(
            path: try SdfPath(path),
            specType: specType,
            specifier: specifier,
            typeName: typeName,
            fieldNames: fieldNames,
            fields: fields
        )
    }

    public init(layerSpec: USDLayerSpec) throws {
        let fields = try layerSpec.fields.mapValues { try SdfFieldValue(layerFieldValue: $0) }
        self.init(
            path: try SdfPath(layerSpec.path),
            specType: layerSpec.specType,
            specifier: layerSpec.specifier,
            typeName: layerSpec.typeName,
            fieldNames: layerSpec.fieldNames,
            fields: fields
        )
    }

    public var isInert: Bool {
        specifier == nil && typeName == nil && fields.isEmpty
    }

    public func validate() throws {
        try validatePathCompatibility()
        try validateFieldNames()
    }

    public func field(named name: String) -> SdfFieldValue? {
        fields[name]
    }

    public func hasField(named name: String) -> Bool {
        fields[name] != nil
    }

    public func listFields() -> [String] {
        var emitted: Set<String> = []
        var names: [String] = []
        for fieldName in fieldNames where fields[fieldName] != nil {
            names.append(fieldName)
            emitted.insert(fieldName)
        }
        names.append(contentsOf: fields.keys.filter { !emitted.contains($0) }.sorted())
        return names
    }

    public mutating func setField(_ value: SdfFieldValue, for name: String) {
        if !fieldNames.contains(name) {
            fieldNames.append(name)
        }
        fields[name] = value
    }

    public mutating func clearField(named name: String) {
        fieldNames.removeAll { $0 == name }
        fields.removeValue(forKey: name)
    }

    public func toUSDLayerSpec() -> USDLayerSpec {
        USDLayerSpec(
            path: path.rawValue,
            specType: specType,
            specifier: specifier,
            typeName: typeName,
            fieldNames: fieldNames,
            fields: fields.mapValues { $0.toUSDLayerFieldValue() }
        )
    }

    internal func validateUSDAExportSupport() throws {
        for fieldName in listFields() {
            guard let fieldValue = fields[fieldName] else {
                continue
            }
            try fieldValue.validateUSDAExportSupport(fieldName: fieldName, path: path)
        }
    }

    private func validatePathCompatibility() throws {
        switch specType {
        case .pseudoRoot:
            guard path.kind == .pseudoRoot else {
                throw USDError.invalidData("SdfSpec pseudoRoot path must be '/'.")
            }
        case .prim:
            guard path.kind == .prim else {
                throw USDError.invalidData("SdfSpec prim path \(path.rawValue) is not a prim path.")
            }
        case .attribute, .relationship:
            guard path.kind == .property else {
                throw USDError.invalidData("SdfSpec \(specType) path \(path.rawValue) is not a property path.")
            }
        case .connection, .relationshipTarget:
            guard path.kind == .propertyTarget else {
                throw USDError.invalidData("SdfSpec \(specType) path \(path.rawValue) is not a property target path.")
            }
        case .variantSet:
            guard path.kind == .variantSet else {
                throw USDError.invalidData("SdfSpec variantSet path \(path.rawValue) is not a variant set path.")
            }
        case .variant:
            guard path.kind == .variantSelection else {
                throw USDError.invalidData("SdfSpec variant path \(path.rawValue) is not a variant selection path.")
            }
        case .expression, .mapper, .mapperArgument:
            throw USDError.unsupportedFeature("SdfSpec type \(specType) is not supported by swift-OpenUSD authoring yet.")
        }
    }

    private func validateFieldNames() throws {
        var seenNames: Set<String> = []
        for fieldName in fieldNames {
            try Self.validateFieldName(fieldName)
            guard seenNames.insert(fieldName).inserted else {
                throw USDError.invalidData("SdfSpec \(path.rawValue) contains duplicate field name \(fieldName).")
            }
            guard fields[fieldName] != nil else {
                throw USDError.invalidData("SdfSpec \(path.rawValue) lists field \(fieldName) without a value.")
            }
        }
        for fieldName in fields.keys {
            try Self.validateFieldName(fieldName)
        }
    }

    private static func validateFieldName(_ name: String) throws {
        guard !name.isEmpty else {
            throw USDError.invalidData("SdfSpec field name must not be empty.")
        }
        guard !name.contains(where: { $0.isWhitespace || $0 == "=" || $0 == "(" || $0 == ")" }) else {
            throw USDError.invalidData("SdfSpec field name \(name) is invalid.")
        }
    }
}
