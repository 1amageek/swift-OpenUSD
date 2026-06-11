import Foundation

public struct USDStage: Sendable, Equatable {
    public private(set) var rootLayer: USDALayer

    public init(rootLayer: USDALayer = USDALayer(specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)])) {
        self.rootLayer = rootLayer
    }

    public init(rootLayer: SdfLayer) {
        self.init(rootLayer: rootLayer.toUSDALayer())
    }

    private func spec(at path: String) -> USDLayerSpec? {
        rootLayer.spec(at: path)
    }

    public static func createInMemory(
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil
    ) -> USDStage {
        USDStage(rootLayer: USDALayer(
            defaultPrim: defaultPrim,
            metersPerUnit: metersPerUnit,
            upAxis: upAxis,
            specs: [USDLayerSpec(path: "/", specType: .pseudoRoot)]
        ))
    }

    public func prim(at path: SdfPath) -> USDPrim? {
        guard let spec = spec(at: path.rawValue), spec.specType == .prim else {
            return nil
        }
        return USDPrim(path: path, specifier: spec.specifier ?? .def, typeName: spec.typeName)
    }

    public func prim(
        at path: SdfPath,
        resolvingWith provider: any USDLayerProvider,
        rootIdentifier: String = "root"
    ) throws -> USDPrim? {
        let layer = try flattenedLayer(resolvingWith: provider, rootIdentifier: rootIdentifier)
        guard let spec = layer.spec(at: path.rawValue), spec.specType == .prim else {
            return nil
        }
        return USDPrim(path: path, specifier: spec.specifier ?? .def, typeName: spec.typeName)
    }

    public func flattenedLayer(
        resolvingWith provider: any USDLayerProvider,
        rootIdentifier: String = "root"
    ) throws -> USDALayer {
        try USDStageCompositionResolver(
            rootLayer: rootLayer,
            rootIdentifier: rootIdentifier,
            provider: provider
        ).flattenedLayer()
    }

    public func resolved(
        resolvingWith provider: any USDLayerProvider,
        rootIdentifier: String = "root"
    ) throws -> USDStage {
        try USDStage(rootLayer: flattenedLayer(resolvingWith: provider, rootIdentifier: rootIdentifier))
    }

    @discardableResult
    public mutating func definePrim(at path: SdfPath, typeName: String? = nil) throws -> USDPrim {
        try validatePrimPath(path)
        ensureDefinedAncestors(for: path)
        return authorPrim(at: path, specifier: .def, typeName: typeName)
    }

    @discardableResult
    public mutating func overridePrim(at path: SdfPath, typeName: String? = nil) throws -> USDPrim {
        try validatePrimPath(path)
        ensureDefinedAncestors(for: path)
        return authorPrim(at: path, specifier: .over, typeName: typeName)
    }

    @discardableResult
    public mutating func createClassPrim(at path: SdfPath, typeName: String? = nil) throws -> USDPrim {
        try validatePrimPath(path)
        guard path.parentPath == .absoluteRoot else {
            throw USDError.invalidData("USD class prim path must be a root prim path.")
        }
        return authorPrim(at: path, specifier: .class, typeName: typeName)
    }

    public mutating func setDefaultPrim(_ prim: USDPrim) throws {
        guard prim.path.parentPath == .absoluteRoot else {
            throw USDError.invalidData("USD defaultPrim must be a root prim.")
        }
        guard spec(at: prim.path.rawValue)?.specType == .prim else {
            throw USDError.invalidData("USD defaultPrim must reference an authored prim.")
        }
        rootLayer.defaultPrim = prim.name
        setLayerMetadata(name: "defaultPrim", value: "\"\(escaped(prim.name))\"")
    }

    public mutating func clearDefaultPrim() {
        rootLayer.defaultPrim = nil
        clearLayerMetadata(name: "defaultPrim")
    }

    @discardableResult
    public mutating func createAttribute(
        at primPath: SdfPath,
        name: String,
        typeName: String,
        defaultValue: String? = nil,
        variability: SdfVariability? = nil,
        custom: Bool = false
    ) throws -> USDAttribute {
        try validateExistingPrimPath(primPath)
        guard !typeName.isEmpty else {
            throw USDError.invalidData("USD attribute typeName must not be empty.")
        }
        let path = try primPath.appendingProperty(name)
        var fieldNames = ["typeName"]
        var fields: [String: USDLayerFieldValue] = ["typeName": .authored(typeName)]
        if custom {
            fieldNames.insert("custom", at: 0)
            fields["custom"] = .authored("true")
        }
        if let variability {
            fieldNames.append("variability")
            fields["variability"] = .authored(variability.authoringToken)
        }
        if let defaultValue {
            fieldNames.append("default")
            fields["default"] = .authored(defaultValue)
        }
        rootLayer.setSpec(USDLayerSpec(
            path: path.rawValue,
            specType: .attribute,
            typeName: typeName,
            fieldNames: fieldNames,
            fields: fields
        ))
        try appendPropertyOrder(path.rawValue, toPrimAt: primPath.rawValue)
        return USDAttribute(path: path, name: name, typeName: typeName)
    }

    public mutating func setAttributeDefault(at path: SdfPath, value: String) throws {
        guard var spec = spec(at: path.rawValue), spec.specType == .attribute else {
            throw USDError.invalidData("USD attribute \(path.rawValue) is not authored.")
        }
        if !spec.fieldNames.contains("default") {
            spec.fieldNames.append("default")
        }
        spec.fields["default"] = .authored(value)
        rootLayer.setSpec(spec)
    }

    @discardableResult
    public mutating func createRelationship(
        at primPath: SdfPath,
        name: String,
        targetPaths: SdfListOperation<SdfPath>? = nil,
        custom: Bool = false
    ) throws -> USDRelationship {
        try validateExistingPrimPath(primPath)
        let path = try primPath.appendingProperty(name)
        var fieldNames: [String] = []
        var fields: [String: USDLayerFieldValue] = [:]
        if custom {
            fieldNames.append("custom")
            fields["custom"] = .authored("true")
        }
        if let targetPaths {
            try validateRelationshipTargetPaths(targetPaths)
            fieldNames.append("targetPaths")
            fields["targetPaths"] = .pathListOperation(targetPaths.mapItems(\.rawValue))
        }
        rootLayer.setSpec(USDLayerSpec(path: path.rawValue, specType: .relationship, fieldNames: fieldNames, fields: fields))
        try appendPropertyOrder(path.rawValue, toPrimAt: primPath.rawValue)
        return USDRelationship(path: path, name: name)
    }

    public func exportUSDA() throws -> String {
        try USDAWriter().string(for: rootLayer)
    }

    public func exportUSDAData() throws -> Data {
        try USDAWriter().data(for: rootLayer)
    }

    public func exportSdfLayer() throws -> SdfLayer {
        try SdfLayer(usdLayer: rootLayer)
    }

    @discardableResult
    mutating func authorPrim(at path: SdfPath, specifier: SdfSpecifier, typeName: String?) -> USDPrim {
        let existing = spec(at: path.rawValue)
        var fieldNames = existing?.fieldNames ?? []
        var fields = existing?.fields ?? [:]
        if !fieldNames.contains("specifier") {
            fieldNames.insert("specifier", at: 0)
        }
        fields["specifier"] = .authored(specifier.authoringToken)
        let authoredTypeName = typeName.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.typeName
        if let authoredTypeName, !authoredTypeName.isEmpty {
            if !fieldNames.contains("typeName") {
                let insertionIndex = fieldNames.firstIndex(of: "specifier").map { fieldNames.index(after: $0) } ?? fieldNames.endIndex
                fieldNames.insert("typeName", at: insertionIndex)
            }
            fields["typeName"] = .authored(authoredTypeName)
        }
        rootLayer.setSpec(USDLayerSpec(
            path: path.rawValue,
            specType: .prim,
            specifier: specifier,
            typeName: authoredTypeName,
            fieldNames: fieldNames,
            fields: fields
        ))
        return USDPrim(path: path, specifier: specifier, typeName: authoredTypeName)
    }

    private mutating func ensureDefinedAncestors(for path: SdfPath) {
        var ancestors: [SdfPath] = []
        var current = path.parentPath
        while let ancestor = current, ancestor != .absoluteRoot {
            ancestors.append(ancestor)
            current = ancestor.parentPath
        }
        for ancestor in ancestors.reversed() {
            guard let spec = spec(at: ancestor.rawValue) else {
                authorPrim(at: ancestor, specifier: .def, typeName: nil)
                continue
            }
            if spec.specType == .prim, spec.specifier == .def {
                continue
            }
            authorPrim(at: ancestor, specifier: .def, typeName: spec.typeName)
        }
    }

    private func validateExistingPrimPath(_ primPath: SdfPath) throws {
        try validatePrimPath(primPath)
        guard spec(at: primPath.rawValue)?.specType == .prim else {
            throw USDError.invalidData("USD prim \(primPath.rawValue) is not authored.")
        }
    }

    /// Stage authoring is restricted to plain absolute prim paths: SdfPath
    /// also admits relative paths, `.`/`..` components, and interior variant
    /// selections, none of which are valid authoring targets here.
    private func validatePrimPath(_ path: SdfPath) throws {
        guard path.isAbsolute, !path.isPseudoRoot else {
            throw USDError.invalidData("USD prim path must be an absolute prim path.")
        }
        guard path.isPrimPath, !path.rawValue.contains("{"), !path.rawValue.contains(".") else {
            throw USDError.invalidData("USD prim path must not contain properties or variant selections.")
        }
    }

    private func validateRelationshipTargetPaths(_ operation: SdfListOperation<SdfPath>) throws {
        let paths = operation.explicitItems
            + operation.addedItems
            + operation.prependedItems
            + operation.appendedItems
            + operation.deletedItems
            + operation.orderedItems
        for path in paths {
            guard !path.isPropertyTargetPath else {
                throw USDError.invalidData("USD relationship target path must not be a property target path.")
            }
        }
    }

    private mutating func setLayerMetadata(name: String, value: String) {
        var pseudoRoot = spec(at: "/") ?? USDLayerSpec(path: "/", specType: .pseudoRoot)
        if !pseudoRoot.fieldNames.contains(name) {
            pseudoRoot.fieldNames.append(name)
        }
        pseudoRoot.fields[name] = .authored(value)
        rootLayer.setSpec(pseudoRoot)
    }

    private mutating func clearLayerMetadata(name: String) {
        guard var pseudoRoot = spec(at: "/") else {
            return
        }
        pseudoRoot.fieldNames.removeAll { $0 == name }
        pseudoRoot.fields.removeValue(forKey: name)
        rootLayer.setSpec(pseudoRoot)
    }

    /// Records `propertyPath` in the prim's property order metadata,
    /// preserving the storage form already authored on the field: a path
    /// list operation stays a list operation, raw text stays raw text.
    private mutating func appendPropertyOrder(_ propertyPath: String, toPrimAt primPath: String) throws {
        guard var primSpec = spec(at: primPath) else {
            throw USDError.invalidData("USD prim \(primPath) is not authored.")
        }
        switch primSpec.fields["properties"] {
        case nil, .authored:
            var orderedPaths = authoredPropertyOrder(for: primSpec)
            guard !orderedPaths.contains(propertyPath) else {
                return
            }
            orderedPaths.append(propertyPath)
            primSpec.fields["properties"] = .authored(orderedPaths.joined(separator: ", "))
        case .pathListOperation(var operation):
            guard !operation.effectiveItems.contains(propertyPath) else {
                return
            }
            operation.deletedItems.removeAll { $0 == propertyPath }
            if operation.isExplicit {
                operation.explicitItems.append(propertyPath)
            } else {
                operation.appendedItems.append(propertyPath)
            }
            primSpec.fields["properties"] = .pathListOperation(operation)
        default:
            throw USDError.invalidData(
                "USD prim \(primPath) properties metadata has an unsupported storage form."
            )
        }
        if !primSpec.fieldNames.contains("properties") {
            primSpec.fieldNames.append("properties")
        }
        rootLayer.setSpec(primSpec)
    }

    private func authoredPropertyOrder(for spec: USDLayerSpec) -> [String] {
        guard let text = spec.fields["properties"]?.authoredText else {
            return []
        }
        return text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension SdfSpecifier {
    var authoringToken: String {
        switch self {
        case .def:
            "def"
        case .over:
            "over"
        case .class:
            "class"
        case .unknown(let payload):
            "unknown(\(payload))"
        }
    }
}

private extension SdfVariability {
    var authoringToken: String {
        switch self {
        case .varying:
            "varying"
        case .uniform:
            "uniform"
        }
    }
}

private extension USDLayerFieldValue {
    var authoredText: String? {
        guard case .authored(let text) = self else {
            return nil
        }
        return text
    }
}
