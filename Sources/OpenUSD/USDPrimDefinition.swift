public struct USDPrimDefinition: Sendable, Equatable, Hashable {
    public var typeName: String
    public var schemaKind: USDSchemaKind
    public var fallbackPrimTypes: [String]
    public var appliedAPISchemas: [String]
    public var propertyNames: [String]
    public var fallbackFields: [String: SdfFieldValue]
    public var apiSchemaPropertyNamespacePrefix: String?

    public init(
        typeName: String,
        schemaKind: USDSchemaKind,
        fallbackPrimTypes: [String] = [],
        appliedAPISchemas: [String] = [],
        propertyNames: [String] = [],
        fallbackFields: [String: SdfFieldValue] = [:],
        apiSchemaPropertyNamespacePrefix: String? = nil
    ) {
        self.typeName = typeName
        self.schemaKind = schemaKind
        self.fallbackPrimTypes = fallbackPrimTypes
        self.appliedAPISchemas = appliedAPISchemas
        self.propertyNames = propertyNames
        self.fallbackFields = fallbackFields
        self.apiSchemaPropertyNamespacePrefix = apiSchemaPropertyNamespacePrefix
    }

    public func merging(_ stronger: USDPrimDefinition) -> USDPrimDefinition {
        USDPrimDefinition(
            typeName: stronger.typeName,
            schemaKind: stronger.schemaKind,
            fallbackPrimTypes: stronger.fallbackPrimTypes.isEmpty ? fallbackPrimTypes : stronger.fallbackPrimTypes,
            appliedAPISchemas: unique(appliedAPISchemas + stronger.appliedAPISchemas),
            propertyNames: unique(propertyNames + stronger.propertyNames),
            fallbackFields: fallbackFields.merging(stronger.fallbackFields) { _, strong in strong },
            apiSchemaPropertyNamespacePrefix: stronger.apiSchemaPropertyNamespacePrefix ?? apiSchemaPropertyNamespacePrefix
        )
    }

    private func unique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
