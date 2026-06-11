import Foundation

public struct USDSchemaRegistry: Sendable, Equatable {
    public private(set) var definitions: [String: USDPrimDefinition]

    public init(includeBuiltInDefinitions: Bool = true) {
        definitions = includeBuiltInDefinitions ? Self.builtInDefinitions : [:]
    }

    public init(plugins: [USDPlugin], includeBuiltInDefinitions: Bool = true) throws {
        definitions = includeBuiltInDefinitions ? Self.builtInDefinitions : [:]
        for plugin in plugins {
            try register(plugin: plugin)
        }
    }

    public func definition(for typeName: String) -> USDPrimDefinition? {
        definitions[typeName]
    }

    public func schemaKind(for typeName: String) -> USDSchemaKind? {
        definitions[typeName]?.schemaKind
            ?? definitions[Self.appliedAPISchemaName(from: typeName).schemaName]?.schemaKind
    }

    public func isConcrete(_ typeName: String) -> Bool {
        schemaKind(for: typeName)?.isConcrete == true
    }

    public func isAppliedAPISchema(_ typeName: String) -> Bool {
        schemaKind(for: typeName)?.isAppliedAPI == true
    }

    public func isA(_ primTypeName: String, _ schemaTypeName: String) -> Bool {
        guard primTypeName != schemaTypeName else {
            return true
        }
        var visited: Set<String> = []
        var pending = definitions[primTypeName]?.fallbackPrimTypes ?? []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else {
                continue
            }
            if current == schemaTypeName {
                return true
            }
            pending.append(contentsOf: definitions[current]?.fallbackPrimTypes ?? [])
        }
        return false
    }

    public func composedDefinition(
        primType: String,
        appliedAPISchemas: [String]
    ) throws -> USDPrimDefinition {
        let primDefinition = definitions[primType] ?? USDPrimDefinition(typeName: primType, schemaKind: .invalid)
        var result = USDPrimDefinition(typeName: "", schemaKind: .invalid)
        for apiSchema in appliedAPISchemas {
            let apiDefinition = try appliedAPISchemaDefinition(for: apiSchema)
            result = result.merging(apiDefinition)
        }
        result = result.merging(primDefinition)
        result.appliedAPISchemas = unique(appliedAPISchemas + primDefinition.appliedAPISchemas + result.appliedAPISchemas)
        return result
    }

    public mutating func register(_ definition: USDPrimDefinition) throws {
        guard !definition.typeName.isEmpty else {
            throw USDError.invalidData("USD schema definition typeName must not be empty.")
        }
        definitions[definition.typeName] = definition
    }

    public mutating func register(plugin: USDPlugin) throws {
        guard let value = plugin.info["Types"] else {
            return
        }
        guard case .dictionary(let types) = value else {
            throw USDError.invalidData("USD schema plugin \(plugin.name) Types metadata must be an object.")
        }
        let schemaIdentifierByTypeName = try Self.schemaIdentifierByTypeName(from: types)
        var pendingDefinitions: [String: USDPrimDefinition] = [:]
        let generatedDefinitions = try Self.generatedSchemaDefinitions(for: plugin)
        for typeKey in types.keys.sorted() {
            guard case .dictionary(let metadata)? = types[typeKey] else {
                throw USDError.invalidData("USD schema plugin type \(typeKey) metadata must be an object.")
            }
            guard Self.isSchemaMetadata(metadata) else {
                continue
            }
            let definition = try Self.definition(
                typeKey: typeKey,
                metadata: metadata,
                schemaIdentifierByTypeName: schemaIdentifierByTypeName
            )
            pendingDefinitions[definition.typeName] = definition
        }
        guard generatedDefinitions.isEmpty || !pendingDefinitions.isEmpty else {
            throw USDError.invalidData("USD schema plugin \(plugin.name) has generatedSchema.usda but no schema Types metadata.")
        }
        for (typeName, generatedDefinition) in generatedDefinitions {
            if let metadataDefinition = pendingDefinitions[typeName] {
                pendingDefinitions[typeName] = generatedDefinition.merging(metadataDefinition)
            } else {
                pendingDefinitions[typeName] = generatedDefinition
            }
        }
        try Self.validateGeneratedSchemaCoverage(plugin: plugin, types: types, generatedDefinitions: generatedDefinitions)
        for typeName in pendingDefinitions.keys.sorted() {
            try register(pendingDefinitions[typeName] ?? USDPrimDefinition(typeName: typeName, schemaKind: .invalid))
        }
    }

    private static func schemaIdentifierByTypeName(
        from types: [String: USDPluginMetadataValue]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for typeKey in types.keys.sorted() {
            guard case .dictionary(let metadata)? = types[typeKey] else {
                throw USDError.invalidData("USD schema plugin type \(typeKey) metadata must be an object.")
            }
            guard isSchemaMetadata(metadata) else {
                continue
            }
            let schemaIdentifier = try optionalString(named: "schemaIdentifier", in: metadata)
                ?? optionalString(named: "primTypeName", in: metadata)
                ?? optionalString(named: "typeName", in: metadata)
                ?? optionalString(named: "schemaTypeName", in: metadata)
                ?? typeKey
            result[typeKey] = schemaIdentifier
        }
        return result
    }

    private static func isSchemaMetadata(_ metadata: [String: USDPluginMetadataValue]) -> Bool {
        metadata["schemaKind"] != nil
            || metadata["apiSchemaType"] != nil
            || metadata["schemaIdentifier"] != nil
            || metadata["primTypeName"] != nil
            || metadata["schemaTypeName"] != nil
            || metadata["propertyNames"] != nil
            || metadata["fallbackFields"] != nil
            || metadata["appliedAPISchemas"] != nil
            || metadata["fallbackPrimTypes"] != nil
    }

    private static func validateGeneratedSchemaCoverage(
        plugin: USDPlugin,
        types: [String: USDPluginMetadataValue],
        generatedDefinitions: [String: USDPrimDefinition]
    ) throws {
        for typeKey in types.keys.sorted() {
            guard case .dictionary(let metadata)? = types[typeKey], isSchemaMetadata(metadata) else {
                continue
            }
            guard case .bool(true)? = metadata["autoGenerated"] else {
                continue
            }
            let schemaIdentifier = try optionalString(named: "schemaIdentifier", in: metadata)
                ?? optionalString(named: "primTypeName", in: metadata)
                ?? optionalString(named: "typeName", in: metadata)
                ?? optionalString(named: "schemaTypeName", in: metadata)
                ?? typeKey
            let hasExplicitDefinition = metadata["propertyNames"] != nil || metadata["fallbackFields"] != nil
            if generatedDefinitions[schemaIdentifier] == nil && !hasExplicitDefinition {
                throw USDError.unsupportedFeature(
                    "USD schema plugin \(plugin.name) type \(typeKey) is generated but generatedSchema.usda was not available."
                )
            }
        }
    }

    private static func generatedSchemaDefinitions(for plugin: USDPlugin) throws -> [String: USDPrimDefinition] {
        let schemaURL = URL(fileURLWithPath: plugin.resourcePath).appendingPathComponent("generatedSchema.usda")
        guard FileManager.default.fileExists(atPath: schemaURL.path) else {
            return [:]
        }
        let layer = try SdfLayer.importUSDA(from: Data(contentsOf: schemaURL), identifier: schemaURL.path)
        var definitions: [String: USDPrimDefinition] = [:]
        for spec in layer.specs where spec.specType == .prim && spec.specifier == .class {
            let typeName = spec.typeName ?? spec.path.name
            guard !typeName.isEmpty else {
                continue
            }
            let propertySpecs = layer.specs.filter { childSpec in
                (childSpec.specType == .attribute || childSpec.specType == .relationship)
                    && childSpec.path.primPath == spec.path
            }
            var fallbackFields: [String: SdfFieldValue] = [:]
            var propertyNames: [String] = []
            for propertySpec in propertySpecs {
                guard let propertyName = propertySpec.path.propertyName else {
                    continue
                }
                propertyNames.append(propertyName)
                if let defaultValue = propertySpec.fields["default"] {
                    fallbackFields[propertyName] = fallbackFieldValue(
                        from: defaultValue,
                        typeName: propertySpec.typeName
                    )
                }
            }
            definitions[typeName] = USDPrimDefinition(
                typeName: typeName,
                schemaKind: .invalid,
                propertyNames: uniqueStrings(propertyNames),
                fallbackFields: fallbackFields
            )
        }
        return definitions
    }

    private static func definition(
        typeKey: String,
        metadata: [String: USDPluginMetadataValue],
        schemaIdentifierByTypeName: [String: String]
    ) throws -> USDPrimDefinition {
        let typeName = try optionalString(named: "primTypeName", in: metadata)
            ?? optionalString(named: "schemaIdentifier", in: metadata)
            ?? optionalString(named: "typeName", in: metadata)
            ?? optionalString(named: "schemaTypeName", in: metadata)
            ?? typeKey
        let schemaKind = try schemaKind(from: metadata)
        let fallbackPrimTypes = try stringArray(named: "fallbackPrimTypes", in: metadata)
        let baseTypes = try stringArray(named: "bases", in: metadata)
        return USDPrimDefinition(
            typeName: typeName,
            schemaKind: schemaKind,
            fallbackPrimTypes: fallbackPrimTypes.isEmpty
                ? baseTypes.map { schemaIdentifierByTypeName[$0] ?? normalizedBaseSchemaName($0) }
                : fallbackPrimTypes.map { schemaIdentifierByTypeName[$0] ?? normalizedBaseSchemaName($0) },
            appliedAPISchemas: try stringArray(named: "appliedAPISchemas", in: metadata),
            propertyNames: try stringArray(named: "propertyNames", in: metadata),
            fallbackFields: try fallbackFields(in: metadata),
            apiSchemaPropertyNamespacePrefix: try optionalString(named: "apiSchemaPropertyNamespacePrefix", in: metadata)
        )
    }

    private static func schemaKind(from metadata: [String: USDPluginMetadataValue]) throws -> USDSchemaKind {
        if let value = metadata["schemaKind"] {
            guard let rawValue = value.stringValue,
                  let kind = USDSchemaKind(rawValue: rawValue) else {
                throw USDError.invalidData("USD schema schemaKind must be a valid USDSchemaKind string.")
            }
            return kind
        }
        let apiSchemaType: String?
        if let value = metadata["apiSchemaType"] {
            guard let string = value.stringValue else {
                throw USDError.invalidData("USD schema apiSchemaType must be a string.")
            }
            apiSchemaType = string
        } else {
            apiSchemaType = nil
        }
        switch apiSchemaType {
        case "nonApplied":
            return .nonAppliedAPI
        case "singleApply":
            return .singleApplyAPI
        case "multipleApply":
            return .multipleApplyAPI
        case nil:
            throw USDError.invalidData("USD schema metadata must define schemaKind or apiSchemaType.")
        case .some(let value):
            throw USDError.invalidData("USD schema apiSchemaType \(value) is not supported.")
        }
    }

    private func appliedAPISchemaDefinition(for authoredName: String) throws -> USDPrimDefinition {
        let name = Self.appliedAPISchemaName(from: authoredName)
        guard let definition = definitions[name.schemaName], definition.schemaKind.isAppliedAPI else {
            throw USDError.invalidData("USD schema \(authoredName) is not a registered applied API schema.")
        }
        switch definition.schemaKind {
        case .singleApplyAPI:
            guard name.instanceName == nil else {
                throw USDError.invalidData("USD single-apply API schema \(name.schemaName) must not include an instance name.")
            }
            return definition
        case .multipleApplyAPI:
            guard let instanceName = name.instanceName, !instanceName.isEmpty else {
                throw USDError.invalidData("USD multiple-apply API schema \(name.schemaName) requires an instance name.")
            }
            return Self.instantiatedMultipleApplyDefinition(definition, instanceName: instanceName)
        default:
            throw USDError.invalidData("USD schema \(authoredName) is not an applied API schema.")
        }
    }

    private static func appliedAPISchemaName(from authoredName: String) -> (schemaName: String, instanceName: String?) {
        guard let separator = authoredName.firstIndex(of: ":") else {
            return (authoredName, nil)
        }
        return (
            String(authoredName[..<separator]),
            String(authoredName[authoredName.index(after: separator)...])
        )
    }

    private static func instantiatedMultipleApplyDefinition(
        _ definition: USDPrimDefinition,
        instanceName: String
    ) -> USDPrimDefinition {
        let namespacePrefix = definition.apiSchemaPropertyNamespacePrefix ?? defaultAPISchemaNamespacePrefix(for: definition.typeName)
        var fallbackFields: [String: SdfFieldValue] = [:]
        for key in definition.fallbackFields.keys.sorted() {
            fallbackFields[namespacedMultipleApplyPropertyName(key, namespacePrefix: namespacePrefix, instanceName: instanceName)] =
                definition.fallbackFields[key]
        }
        return USDPrimDefinition(
            typeName: definition.typeName,
            schemaKind: definition.schemaKind,
            fallbackPrimTypes: definition.fallbackPrimTypes,
            appliedAPISchemas: ["\(definition.typeName):\(instanceName)"],
            propertyNames: definition.propertyNames.map {
                namespacedMultipleApplyPropertyName($0, namespacePrefix: namespacePrefix, instanceName: instanceName)
            },
            fallbackFields: fallbackFields,
            apiSchemaPropertyNamespacePrefix: definition.apiSchemaPropertyNamespacePrefix
        )
    }

    private static func namespacedMultipleApplyPropertyName(
        _ propertyName: String,
        namespacePrefix: String,
        instanceName: String
    ) -> String {
        let prefix = "\(namespacePrefix):\(instanceName):"
        guard !propertyName.hasPrefix(prefix) else {
            return propertyName
        }
        return "\(prefix)\(propertyName)"
    }

    private static func defaultAPISchemaNamespacePrefix(for typeName: String) -> String {
        let baseName = typeName.hasSuffix("API") ? String(typeName.dropLast(3)) : typeName
        guard let first = baseName.first else {
            return baseName
        }
        return first.lowercased() + String(baseName.dropFirst())
    }

    private static func optionalString(
        named name: String,
        in metadata: [String: USDPluginMetadataValue]
    ) throws -> String? {
        guard let value = metadata[name] else {
            return nil
        }
        guard let string = value.stringValue else {
            throw USDError.invalidData("USD schema \(name) metadata must be a string.")
        }
        return string
    }

    private static func normalizedBaseSchemaName(_ typeName: String) -> String {
        guard typeName.hasPrefix("Usd"), typeName.count > 3 else {
            return typeName
        }
        let dropped = String(typeName.dropFirst(3))
        for knownPrefix in ["Geom", "Lux", "Shade", "Skel", "Vol", "Physics", "Render", "UI", "Proc"] {
            guard dropped.hasPrefix(knownPrefix), dropped.count > knownPrefix.count else {
                continue
            }
            return String(dropped.dropFirst(knownPrefix.count))
        }
        return dropped
    }

    private static func fallbackFieldValue(from value: SdfFieldValue, typeName: String?) -> SdfFieldValue {
        guard case .authored(let authoredText) = value else {
            return value
        }
        let text = authoredText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch typeName {
        case "token":
            return .token(unquotedString(text) ?? text)
        case "string":
            return .string(unquotedString(text) ?? text)
        case "bool":
            if text == "true" || text == "1" {
                return .bool(true)
            }
            if text == "false" || text == "0" {
                return .bool(false)
            }
            return value
        case "int", "uint", "int64", "uint64":
            guard let intValue = Int(text) else {
                return value
            }
            return .int(intValue)
        case "half", "float", "double":
            guard let doubleValue = Double(text) else {
                return value
            }
            return .double(doubleValue)
        default:
            return value
        }
    }

    private static func unquotedString(_ text: String) -> String? {
        guard text.count >= 2,
              let first = text.first,
              let last = text.last,
              (first == "\"" || first == "'"),
              first == last else {
            return nil
        }
        let body = text.dropFirst().dropLast()
        return body
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
    }

    private static func stringArray(
        named name: String,
        in metadata: [String: USDPluginMetadataValue]
    ) throws -> [String] {
        guard let value = metadata[name] else {
            return []
        }
        guard case .array(let values) = value else {
            throw USDError.invalidData("USD schema \(name) metadata must be an array of strings.")
        }
        var result: [String] = []
        for value in values {
            guard let string = value.stringValue else {
                throw USDError.invalidData("USD schema \(name) metadata must be an array of strings.")
            }
            result.append(string)
        }
        return result
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private static func fallbackFields(
        in metadata: [String: USDPluginMetadataValue]
    ) throws -> [String: SdfFieldValue] {
        guard let value = metadata["fallbackFields"] else {
            return [:]
        }
        guard case .dictionary(let fields) = value else {
            throw USDError.invalidData("USD schema fallbackFields metadata must be an object.")
        }
        var result: [String: SdfFieldValue] = [:]
        for key in fields.keys.sorted() {
            result[key] = try sdfFieldValue(from: fields[key] ?? .null)
        }
        return result
    }

    private static func sdfFieldValue(from value: USDPluginMetadataValue) throws -> SdfFieldValue {
        switch value {
        case .string(let string):
            return .string(string)
        case .number(let number):
            return .double(number)
        case .bool(let bool):
            return .bool(bool)
        case .array(let values):
            if let strings = stringValues(from: values) {
                return .stringVector(strings)
            }
            if let numbers = numberValues(from: values) {
                return .doubleVector(numbers)
            }
            if let bools = boolValues(from: values) {
                return .boolArray(bools)
            }
            throw USDError.invalidData("USD schema fallback array value is not supported.")
        case .dictionary(let dictionary):
            var result: [String: SdfFieldValue] = [:]
            for key in dictionary.keys.sorted() {
                result[key] = try sdfFieldValue(from: dictionary[key] ?? .null)
            }
            return .dictionary(result)
        case .null:
            return .unmaterializedValue
        }
    }

    private static func stringValues(from values: [USDPluginMetadataValue]) -> [String]? {
        var result: [String] = []
        for value in values {
            guard let string = value.stringValue else {
                return nil
            }
            result.append(string)
        }
        return result
    }

    private static func numberValues(from values: [USDPluginMetadataValue]) -> [Double]? {
        var result: [Double] = []
        for value in values {
            guard case .number(let number) = value else {
                return nil
            }
            result.append(number)
        }
        return result
    }

    private static func boolValues(from values: [USDPluginMetadataValue]) -> [Bool]? {
        var result: [Bool] = []
        for value in values {
            guard case .bool(let bool) = value else {
                return nil
            }
            result.append(bool)
        }
        return result
    }

    private func unique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private static let builtInDefinitions: [String: USDPrimDefinition] = {
        let scope = USDPrimDefinition(
            typeName: "Scope",
            schemaKind: .concreteTyped,
            fallbackPrimTypes: []
        )
        let xform = USDPrimDefinition(
            typeName: "Xform",
            schemaKind: .concreteTyped,
            fallbackPrimTypes: ["Scope"],
            propertyNames: ["xformOpOrder"]
        )
        let mesh = USDPrimDefinition(
            typeName: "Mesh",
            schemaKind: .concreteTyped,
            fallbackPrimTypes: ["Xform"],
            propertyNames: [
                "extent",
                "faceVertexCounts",
                "faceVertexIndices",
                "normals",
                "orientation",
                "points",
                "primvars:displayColor",
                "primvars:displayOpacity",
                "primvars:st",
                "subdivisionScheme",
                "xformOpOrder",
            ],
            fallbackFields: [
                "orientation": .token("rightHanded"),
                "subdivisionScheme": .token("catmullClark"),
            ]
        )
        return Dictionary(uniqueKeysWithValues: [scope, xform, mesh].map { ($0.typeName, $0) })
    }()
}
