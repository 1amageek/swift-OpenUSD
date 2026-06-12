import Foundation

public struct USDAWriter: Sendable {
    public init() {}

    public func data(for scene: USDScene) throws -> Data {
        Data(try string(for: scene).utf8)
    }

    public func string(for scene: USDScene) throws -> String {
        try validateScene(scene)
        var output = "#usda 1.0\n(\n"
        if let defaultPrim = scene.defaultPrim {
            output += "    defaultPrim = \(quoted(defaultPrim))\n"
        }
        output += "    metersPerUnit = \(formatDouble(scene.metersPerUnit))\n"
        output += "    upAxis = \(quoted(scene.upAxis.rawValue))\n"
        output += ")\n"
        for (index, mesh) in scene.meshes.enumerated() {
            output += "\n"
            output += writeMesh(mesh, fallbackIndex: index, indentLevel: 0)
        }
        return output
    }

    public func data(for layer: USDALayer) throws -> Data {
        Data(try string(for: layer).utf8)
    }

    public func string(for layer: USDALayer) throws -> String {
        try SdfLayer(usdLayer: layer).validateUSDAExportSupport()
        var output = "#usda 1.0\n"
        let layerFields = layer.spec(at: "/")?.fields ?? [:]
        let layerFieldNames = layer.spec(at: "/")?.fieldNames ?? []
        let metadataLines = try authoredLayerMetadataLines(layer: layer, fields: layerFields, fieldNames: layerFieldNames)
        if !metadataLines.isEmpty {
            output += "(\n"
            for line in metadataLines {
                output += "    \(line)\n"
            }
            output += ")\n"
        }
        let specIndex = makeSpecIndex(for: layer)
        let rootPrims = specIndex.childPrimSpecs(forParentPath: "")
        if !rootPrims.isEmpty {
            if !metadataLines.isEmpty {
                output += "\n"
            }
            for (index, prim) in rootPrims.enumerated() {
                if index > 0 {
                    output += "\n"
                }
                output += try writePrim(prim, specIndex: specIndex, indentLevel: 0)
            }
        }
        return output
    }

    private func writeMesh(_ mesh: USDMesh, fallbackIndex: Int, indentLevel: Int) -> String {
        let indent = indentation(indentLevel)
        let name = mesh.name ?? mesh.primPath.flatMap(lastPathComponent) ?? "Mesh\(fallbackIndex)"
        var output = "\(indent)def Mesh \(quoted(name))\n\(indent){\n"
        output += "\(indentation(indentLevel + 1))int[] faceVertexCounts = \(intArray(mesh.faceVertexCounts))\n"
        output += "\(indentation(indentLevel + 1))int[] faceVertexIndices = \(intArray(mesh.faceVertexIndices))\n"
        output += "\(indentation(indentLevel + 1))point3f[] points = \(point3Array(mesh.points))\n"
        if !mesh.normals.isEmpty {
            output += "\(indentation(indentLevel + 1))normal3f[] normals"
            if let interpolation = mesh.normalsInterpolation {
                output += " (\n"
                output += "\(indentation(indentLevel + 2))interpolation = \(quoted(interpolation))\n"
                output += "\(indentation(indentLevel + 1)))"
            }
            output += " = \(point3Array(mesh.normals))\n"
        }
        if let orientation = mesh.orientation {
            output += "\(indentation(indentLevel + 1))uniform token orientation = \(quoted(orientation.rawValue))\n"
        }
        if let subdivisionScheme = mesh.subdivisionScheme {
            output += "\(indentation(indentLevel + 1))uniform token subdivisionScheme = \(quoted(subdivisionScheme))\n"
        }
        if let extent = mesh.extent {
            output += "\(indentation(indentLevel + 1))float3[] extent = \(point3Array(extent))\n"
        }
        output += "\(indent)}\n"
        return output
    }

    private func authoredLayerMetadataLines(
        layer: USDALayer,
        fields: [String: USDLayerFieldValue],
        fieldNames: [String]
    ) throws -> [String] {
        var lines: [String] = []
        var emitted: Set<String> = []
        func appendField(_ name: String) throws {
            guard let value = fields[name] else {
                return
            }
            lines.append(contentsOf: try metadataStatementLines(fieldName: name, value: value))
            emitted.insert(name)
        }
        try appendField("defaultPrim")
        try appendField("metersPerUnit")
        try appendField("upAxis")
        for fieldName in fieldNames where !emitted.contains(fieldName) {
            try appendField(fieldName)
        }
        if layer.defaultPrim != nil, !emitted.contains("defaultPrim") {
            lines.append("defaultPrim = \(quoted(layer.defaultPrim ?? ""))")
        }
        if layer.metersPerUnit != nil, !emitted.contains("metersPerUnit") {
            lines.append("metersPerUnit = \(formatDouble(layer.metersPerUnit ?? 0))")
        }
        if layer.upAxis != nil, !emitted.contains("upAxis") {
            lines.append("upAxis = \(quoted(layer.upAxis?.rawValue ?? ""))")
        }
        return lines
    }

    private func writePrim(
        _ spec: USDLayerSpec,
        specIndex: USDAWriterSpecIndex,
        indentLevel: Int
    ) throws -> String {
        let indent = indentation(indentLevel)
        var output = indent
        output += "\(try specifierKeyword(spec.specifier)) "
        if let typeName = spec.typeName, !typeName.isEmpty {
            output += "\(typeName) "
        }
        output += "\(quoted(primName(for: spec.path)))"
        let metadataLines = try primMetadataLines(for: spec)
        if !metadataLines.isEmpty {
            output += " (\n"
            for line in metadataLines {
                output += "\(indentation(indentLevel + 1))\(line)\n"
            }
            output += "\(indent))"
        }
        output += "\n\(indent){\n"
        output += try writePropertyOrderOperations(for: spec, indentLevel: indentLevel + 1)
        let propertySpecs = try directPropertySpecs(parentPrimSpec: spec, specIndex: specIndex)
        for propertySpec in propertySpecs {
            output += try writeProperty(propertySpec, indentLevel: indentLevel + 1)
        }
        let variantSetSpecs = specIndex.variantSetSpecs(forParentPrimPath: spec.path)
        for variantSetSpec in variantSetSpecs {
            output += try writeVariantSet(
                variantSetSpec,
                specIndex: specIndex,
                indentLevel: indentLevel + 1
            )
        }
        let children = specIndex.childPrimSpecs(forParentPath: spec.path)
        for child in children {
            output += try writePrim(child, specIndex: specIndex, indentLevel: indentLevel + 1)
        }
        output += "\(indent)}\n"
        return output
    }

    private func writeVariantSet(
        _ spec: USDLayerSpec,
        specIndex: USDAWriterSpecIndex,
        indentLevel: Int
    ) throws -> String {
        let indent = indentation(indentLevel)
        let name = variantSetName(for: spec.path)
        var output = "\(indent)variantSet \(quoted(name)) = {\n"
        let variants = specIndex.variantSpecs(forVariantSetPath: spec.path)
        if variants.isEmpty, let body = spec.fields["body"]?.authoredText, !body.isEmpty {
            output += indentedBlock(body, level: indentLevel + 1)
        } else {
            for variant in variants {
                let variantName = variantName(for: variant.path)
                output += "\(indentation(indentLevel + 1))\(quoted(variantName)) {\n"
                output += try writeVariantBody(
                    variant,
                    specIndex: specIndex,
                    indentLevel: indentLevel + 2
                )
                output += "\(indentation(indentLevel + 1))}\n"
            }
        }
        output += "\(indent)}\n"
        return output
    }

    private func writeVariantBody(
        _ variant: USDLayerSpec,
        specIndex: USDAWriterSpecIndex,
        indentLevel: Int
    ) throws -> String {
        let rawBody = variant.fields["body"]?.authoredText
        let hasRawBody = rawBody?.isEmpty == false
        let hasStructuredContent = try variantHasStructuredContent(variant, specIndex: specIndex)
        if hasRawBody && hasStructuredContent {
            throw USDError.unsupportedFeature(
                "USDA cannot export variant \(variant.path) because it mixes raw body text with structured child specs."
            )
        }
        if let rawBody, !rawBody.isEmpty {
            return indentedBlock(rawBody, level: indentLevel)
        }
        return try writeContainedSpecs(parentSpec: variant, specIndex: specIndex, indentLevel: indentLevel)
    }

    private func writeContainedSpecs(
        parentSpec: USDLayerSpec,
        specIndex: USDAWriterSpecIndex,
        indentLevel: Int
    ) throws -> String {
        var output = ""
        output += try writePropertyOrderOperations(for: parentSpec, indentLevel: indentLevel)
        let propertySpecs = try directPropertySpecs(parentPrimSpec: parentSpec, specIndex: specIndex)
        for propertySpec in propertySpecs {
            output += try writeProperty(propertySpec, indentLevel: indentLevel)
        }
        let variantSetSpecs = specIndex.variantSetSpecs(forParentPrimPath: parentSpec.path)
        for variantSetSpec in variantSetSpecs {
            output += try writeVariantSet(
                variantSetSpec,
                specIndex: specIndex,
                indentLevel: indentLevel
            )
        }
        let children = specIndex.childPrimSpecs(forParentPath: parentSpec.path)
        for child in children {
            output += try writePrim(child, specIndex: specIndex, indentLevel: indentLevel)
        }
        return output
    }

    private func writeProperty(_ spec: USDLayerSpec, indentLevel: Int) throws -> String {
        let valueFields = propertyValueFieldNames(for: spec)
        guard !valueFields.isEmpty else {
            return try writePropertyStatement(spec, valueFieldName: nil, includeMetadata: true, indentLevel: indentLevel)
        }

        var output = ""
        for (index, valueFieldName) in valueFields.enumerated() {
            output += try writePropertyStatements(
                spec,
                valueFieldName: valueFieldName,
                includeMetadata: index == 0,
                indentLevel: indentLevel
            )
        }
        return output
    }

    private func writePropertyStatements(
        _ spec: USDLayerSpec,
        valueFieldName: String,
        includeMetadata: Bool,
        indentLevel: Int
    ) throws -> String {
        guard case .pathListOperation(let operation)? = spec.fields[valueFieldName] else {
            return try writePropertyStatement(
                spec,
                valueFieldName: valueFieldName,
                includeMetadata: includeMetadata,
                indentLevel: indentLevel
            )
        }
        return try writePathListOperationPropertyStatements(
            spec,
            valueFieldName: valueFieldName,
            operation: operation,
            includeMetadata: includeMetadata,
            indentLevel: indentLevel
        )
    }

    private func writePathListOperationPropertyStatements(
        _ spec: USDLayerSpec,
        valueFieldName: String,
        operation: SdfListOperation<String>,
        includeMetadata: Bool,
        indentLevel: Int
    ) throws -> String {
        var output = ""
        var includesMetadata = includeMetadata
        func appendStatement(operationName: String?, items: [String], allowSingleItem: Bool) throws {
            output += try writePropertyStatement(
                spec,
                valueFieldName: valueFieldName,
                includeMetadata: includesMetadata,
                indentLevel: indentLevel,
                listEditOperation: operationName,
                assignmentOverride: pathListAssignment(items, allowSingleItem: allowSingleItem)
            )
            includesMetadata = false
        }
        if operation.isExplicit {
            try appendStatement(operationName: nil, items: operation.explicitItems, allowSingleItem: true)
        }
        if !operation.deletedItems.isEmpty {
            try appendStatement(operationName: "delete", items: operation.deletedItems, allowSingleItem: false)
        }
        if !operation.addedItems.isEmpty {
            try appendStatement(operationName: "add", items: operation.addedItems, allowSingleItem: false)
        }
        if !operation.prependedItems.isEmpty {
            try appendStatement(operationName: "prepend", items: operation.prependedItems, allowSingleItem: false)
        }
        if !operation.appendedItems.isEmpty {
            try appendStatement(operationName: "append", items: operation.appendedItems, allowSingleItem: false)
        }
        if !operation.orderedItems.isEmpty {
            try appendStatement(operationName: "reorder", items: operation.orderedItems, allowSingleItem: false)
        }
        return output
    }

    private func writePropertyStatement(
        _ spec: USDLayerSpec,
        valueFieldName: String?,
        includeMetadata: Bool,
        indentLevel: Int,
        listEditOperation explicitListEditOperation: String? = nil,
        assignmentOverride: String? = nil
    ) throws -> String {
        let indent = indentation(indentLevel)
        var qualifiers: [String] = []
        if let customValue = spec.fields["custom"] {
            switch customValue.authoredText {
            case "true":
                qualifiers.append("custom")
            case "false":
                break
            default:
                throw USDError.invalidData(
                    "USDA property spec \(spec.path) has a non-boolean custom field value \(customValue)."
                )
            }
        }
        let listEditOperation: String?
        if let explicitListEditOperation {
            listEditOperation = explicitListEditOperation
        } else {
            listEditOperation = try propertyListEditOperationForLegacyAuthoredField(
                spec,
                valueFieldName: valueFieldName
            )
        }
        if let listEditOperation,
           valueFieldName == "connectionPaths" || valueFieldName == "targetPaths" {
            qualifiers.append(listEditOperation)
        }
        if let variabilityValue = spec.fields["variability"] {
            guard let variability = variabilityValue.authoredText,
                  variability == "uniform" || variability == "varying" else {
                throw USDError.unsupportedFeature(
                    "USDA property spec \(spec.path) has an unsupported variability value \(variabilityValue)."
                )
            }
            qualifiers.append(variability)
        }
        let typeName: String
        if spec.specType == .relationship {
            typeName = "rel"
        } else if let specTypeName = spec.typeName, !specTypeName.isEmpty {
            typeName = specTypeName
        } else {
            throw USDError.invalidData(
                "USDA attribute spec \(spec.path) is missing a type name and cannot be exported."
            )
        }
        let name = authoredPropertyName(for: spec, valueFieldName: valueFieldName)
        let metadataLines = includeMetadata ? try propertyMetadataLines(for: spec) : []
        let qualifierPrefix = qualifiers.isEmpty ? "" : "\(qualifiers.joined(separator: " ")) "
        var output = "\(indent)\(qualifierPrefix)\(typeName) \(name)"
        if !metadataLines.isEmpty {
            output += " (\n"
            for line in metadataLines {
                output += "\(indentation(indentLevel + 1))\(line)\n"
            }
            output += "\(indent))"
        }
        let assignment = try assignmentOverride ?? valueFieldName.flatMap { fieldName in
            try spec.fields[fieldName].flatMap(propertyAssignmentText)
        }
        if let assignment {
            output += " = \(formattedAssignmentValue(assignment, indentLevel: indentLevel))"
        }
        output += "\n"
        return output
    }

    private func propertyAssignmentText(_ value: USDLayerFieldValue) throws -> String? {
        switch value {
        case .authored(let text):
            return text
        case .timeSamples(let samples):
            return try SdfFieldValue.timeSamplesText(samples)
        default:
            return nil
        }
    }

    private func pathListAssignment(_ items: [String], allowSingleItem: Bool) -> String {
        if allowSingleItem, items.count == 1 {
            return "<\(items[0])>"
        }
        return "[\(items.map { "<\($0)>" }.joined(separator: ", "))]"
    }

    private func authoredPropertyName(for spec: USDLayerSpec, valueFieldName: String?) -> String {
        switch valueFieldName {
        case "connectionPaths":
            "\(propertyName(for: spec.path)).connect"
        case "timeSamples":
            "\(propertyName(for: spec.path)).timeSamples"
        default:
            propertyName(for: spec.path)
        }
    }

    private func propertyValueFieldNames(for spec: USDLayerSpec) -> [String] {
        let valueFieldNames: Set<String>
        if spec.specType == .relationship {
            valueFieldNames = ["targetPaths"]
        } else {
            valueFieldNames = ["default", "connectionPaths", "timeSamples"]
        }
        var emitted: Set<String> = []
        var names: [String] = []
        for fieldName in spec.fieldNames where valueFieldNames.contains(fieldName) && spec.fields[fieldName] != nil {
            names.append(fieldName)
            emitted.insert(fieldName)
        }
        for fieldName in ["default", "connectionPaths", "timeSamples", "targetPaths"]
            where valueFieldNames.contains(fieldName)
                && spec.fields[fieldName] != nil
                && !emitted.contains(fieldName) {
            names.append(fieldName)
        }
        return names
    }

    private func writePropertyOrderOperations(for spec: USDLayerSpec, indentLevel: Int) throws -> String {
        guard case .pathListOperation(let operation)? = spec.fields["properties"] else {
            return ""
        }
        let indent = indentation(indentLevel)
        var output = ""
        func appendOperation(_ operationName: String, items: [String]) {
            guard !items.isEmpty else {
                return
            }
            let value = propertyOrderAssignment(items, parentPrimPath: spec.path)
            output += "\(indent)\(operationName) properties = \(value)\n"
        }
        if operation.isExplicit {
            appendOperation("reorder", items: operation.explicitItems)
        }
        appendOperation("delete", items: operation.deletedItems)
        appendOperation("add", items: operation.addedItems)
        appendOperation("prepend", items: operation.prependedItems)
        appendOperation("append", items: operation.appendedItems)
        appendOperation("reorder", items: operation.orderedItems)
        return output
    }

    private func propertyOrderAssignment(_ items: [String], parentPrimPath: String) -> String {
        let names = items.map { propertyOrderItemName($0, parentPrimPath: parentPrimPath) }
        return "[\(names.map(quoted).joined(separator: ", "))]"
    }

    private func propertyOrderItemName(_ path: String, parentPrimPath: String) -> String {
        let prefix = parentPrimPath + "."
        guard path.hasPrefix(prefix) else {
            return path
        }
        return String(path.dropFirst(prefix.count))
    }

    private func directPropertySpecs(
        parentPrimSpec parentSpec: USDLayerSpec,
        specIndex: USDAWriterSpecIndex
    ) throws -> [USDLayerSpec] {
        // Document order: the index preserves the insertion order of the
        // layer's specs array within each group.
        let documentOrderSpecs = specIndex.propertySpecs(forOwnerPath: parentSpec.path)
        var specsByPath: [String: USDLayerSpec] = [:]
        for documentOrderSpec in documentOrderSpecs {
            guard specsByPath.updateValue(documentOrderSpec, forKey: documentOrderSpec.path) == nil else {
                throw USDError.invalidData("USDA layer contains duplicate property spec \(documentOrderSpec.path).")
            }
        }
        let orderedPaths: [String]
        if let authoredProperties = parentSpec.fields["properties"]?.authoredText {
            orderedPaths = propertyOrder(from: authoredProperties, parentPrimPath: parentSpec.path)
        } else if case .pathListOperation(let operation)? = parentSpec.fields["properties"] {
            orderedPaths = operation.orderedItems.isEmpty ? operation.effectiveItems : operation.orderedItems
        } else {
            return documentOrderSpecs
        }
        var orderedSpecs: [USDLayerSpec] = []
        orderedSpecs.reserveCapacity(documentOrderSpecs.count)
        var emittedPaths: Set<String> = []
        for path in orderedPaths {
            guard let orderedSpec = specsByPath[path], !emittedPaths.contains(path) else {
                continue
            }
            orderedSpecs.append(orderedSpec)
            emittedPaths.insert(path)
        }
        // Specs missing from the authored order follow in document order.
        for documentOrderSpec in documentOrderSpecs where !emittedPaths.contains(documentOrderSpec.path) {
            orderedSpecs.append(documentOrderSpec)
        }
        return orderedSpecs
    }

    private func propertyOrder(from authoredProperties: String, parentPrimPath: String) -> [String] {
        authoredProperties
            .split(separator: ",")
            .map { normalizedPropertyPath(String($0), parentPrimPath: parentPrimPath) }
            .filter { !$0.isEmpty }
    }

    private func normalizedPropertyPath(_ value: String, parentPrimPath: String) -> String {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip list delimiters that leak in when a bracketed list is split on
        // commas, but keep balanced target brackets such as `/Prim.rel[/Target]`.
        if token.hasPrefix("[") {
            token.removeFirst()
        }
        if token.hasSuffix("]") {
            let openCount = token.count(where: { $0 == "[" })
            let closeCount = token.count(where: { $0 == "]" })
            if closeCount > openCount {
                token.removeLast()
            }
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("<"), token.hasSuffix(">") {
            token.removeFirst()
            token.removeLast()
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\""), token.hasSuffix("\"") {
            token.removeFirst()
            token.removeLast()
        }
        if token.hasPrefix("'"), token.hasSuffix("'") {
            token.removeFirst()
            token.removeLast()
        }
        guard !token.isEmpty else {
            return ""
        }
        if token.hasPrefix(parentPrimPath + ".") {
            return token
        }
        if token.hasPrefix("/") {
            return token
        }
        return propertyPath(parentPrimPath: parentPrimPath, propertyName: token)
    }

    private func variantHasStructuredContent(
        _ variant: USDLayerSpec,
        specIndex: USDAWriterSpecIndex
    ) throws -> Bool {
        if variant.fields["properties"] != nil {
            return true
        }
        if try !directPropertySpecs(parentPrimSpec: variant, specIndex: specIndex).isEmpty {
            return true
        }
        if !specIndex.variantSetSpecs(forParentPrimPath: variant.path).isEmpty {
            return true
        }
        return !specIndex.childPrimSpecs(forParentPath: variant.path).isEmpty
    }

    private func makeSpecIndex(for layer: USDALayer) -> USDAWriterSpecIndex {
        var childPrimSpecsByParentPath: [String: [USDLayerSpec]] = [:]
        var propertySpecsByOwnerPath: [String: [USDLayerSpec]] = [:]
        var variantSetSpecsByParentPrimPath: [String: [USDLayerSpec]] = [:]
        var variantSpecsByVariantSetPath: [String: [USDLayerSpec]] = [:]
        for spec in layer.specs {
            switch spec.specType {
            case .prim:
                childPrimSpecsByParentPath[parentPrimPath(for: spec.path), default: []].append(spec)
            case .attribute, .relationship:
                propertySpecsByOwnerPath[propertyParentPrimPath(for: spec.path), default: []].append(spec)
            case .variantSet:
                variantSetSpecsByParentPrimPath[variantSetParentPrimPath(for: spec.path), default: []].append(spec)
            case .variant:
                variantSpecsByVariantSetPath[variantSetPath(forVariantPath: spec.path), default: []].append(spec)
            default:
                break
            }
        }
        return USDAWriterSpecIndex(
            childPrimSpecsByParentPath: childPrimSpecsByParentPath,
            propertySpecsByOwnerPath: propertySpecsByOwnerPath,
            variantSetSpecsByParentPrimPath: variantSetSpecsByParentPrimPath,
            variantSpecsByVariantSetPath: variantSpecsByVariantSetPath
        )
    }

    private func primMetadataLines(for spec: USDLayerSpec) throws -> [String] {
        try metadataLines(
            for: spec,
            skipping: ["specifier", "typeName", "properties"]
        )
    }

    private func propertyMetadataLines(for spec: USDLayerSpec) throws -> [String] {
        try metadataLines(
            for: spec,
            skipping: [
                "custom",
                "listEditOperation",
                "typeName",
                "variability",
                "default",
                "connectionPaths",
                "timeSamples",
                "targetPaths",
            ]
        )
    }

    private func metadataLines(for spec: USDLayerSpec, skipping skippedNames: Set<String>) throws -> [String] {
        var lines: [String] = []
        var emitted: Set<String> = []
        for fieldName in spec.fieldNames where !skippedNames.contains(fieldName) {
            guard let value = spec.fields[fieldName] else {
                continue
            }
            lines.append(contentsOf: try metadataStatementLines(fieldName: fieldName, value: value))
            emitted.insert(fieldName)
        }
        for fieldName in spec.fields.keys.sorted() where !skippedNames.contains(fieldName) && !emitted.contains(fieldName) {
            lines.append(contentsOf: try metadataStatementLines(fieldName: fieldName, value: spec.fields[fieldName] ?? .authored("")))
        }
        return lines
    }

    private func metadataStatementLines(fieldName: String, value: USDLayerFieldValue) throws -> [String] {
        switch value {
        case .unmaterializedValue:
            throw USDError.unsupportedFeature(
                "USDA cannot export unmaterialized metadata field \(fieldName) without data loss."
            )
        case .authored(let text):
            return ["\(fieldName) = \(text)"]
        case .timeSamples(let samples):
            return ["\(fieldName) = \(try SdfFieldValue.timeSamplesText(samples))"]
        case .dictionary(let values):
            if isStringDictionaryMetadataField(fieldName) {
                return ["\(fieldName) = \(try stringDictionaryText(fieldName: fieldName, values: values))"]
            }
            return ["\(fieldName) = \(try SdfFieldValue.usdaDictionaryText(values))"]
        case .tokenListOperation(let operation):
            return try listOperationStatementLines(fieldName: fieldName, operation: operation) { quoted($0) }
        case .stringListOperation(let operation):
            return try listOperationStatementLines(
                fieldName: authoredStringListMetadataFieldName(fieldName),
                operation: operation
            ) { quoted($0) }
        case .pathListOperation(let operation):
            return try listOperationStatementLines(fieldName: authoredPathListMetadataFieldName(fieldName), operation: operation) { "<\($0)>" }
        case .referenceListOperation(let operation):
            return try listOperationStatementLines(fieldName: fieldName, operation: operation) {
                try referenceText($0)
            }
        case .payloadListOperation(let operation):
            return try listOperationStatementLines(fieldName: fieldName, operation: operation) {
                payloadText($0)
            }
        case .payload(let payload):
            return ["\(fieldName) = \(payloadText(payload))"]
        }
    }

    private func authoredPathListMetadataFieldName(_ fieldName: String) -> String {
        fieldName == "inheritPaths" ? "inherits" : fieldName
    }

    private func authoredStringListMetadataFieldName(_ fieldName: String) -> String {
        fieldName == "variantSetNames" ? "variantSets" : fieldName
    }

    private func isStringDictionaryMetadataField(_ fieldName: String) -> Bool {
        fieldName == "prefixSubstitutions" || fieldName == "suffixSubstitutions"
    }

    private func stringDictionaryText(fieldName: String, values: [String: SdfFieldValue]) throws -> String {
        let lines = try values.keys.sorted().map { key in
            guard !key.isEmpty else {
                throw USDError.invalidData("USDA \(fieldName) metadata keys cannot be empty.")
            }
            guard case .string(let value) = values[key] else {
                throw USDError.invalidData("USDA \(fieldName) metadata values must be strings.")
            }
            return "    \(quoted(key)): \(quoted(value)),"
        }
        guard !lines.isEmpty else {
            return "{}"
        }
        return "{\n\(lines.joined(separator: "\n"))\n}"
    }

    private func listOperationStatementLines<Item: Sendable & Equatable & Hashable>(
        fieldName: String,
        operation: SdfListOperation<Item>,
        formatItem: (Item) throws -> String
    ) throws -> [String] {
        var lines: [String] = []
        func append(
            _ operationName: String?,
            items: [Item],
            forceEmptyList: Bool = false,
            forceList: Bool = false
        ) throws {
            guard forceEmptyList || !items.isEmpty else {
                return
            }
            let prefix = operationName.map { "\($0) " } ?? ""
            lines.append("\(prefix)\(fieldName) = \(try listOperationAssignment(items, forceList: forceList, formatItem: formatItem))")
        }
        if operation.isExplicit {
            try append(nil, items: operation.explicitItems, forceEmptyList: true)
        }
        try append("delete", items: operation.deletedItems)
        try append("add", items: operation.addedItems)
        try append("prepend", items: operation.prependedItems)
        try append("append", items: operation.appendedItems)
        try append("reorder", items: operation.orderedItems, forceList: true)
        return lines
    }

    private func listOperationAssignment<Item>(
        _ items: [Item],
        forceList: Bool = false,
        formatItem: (Item) throws -> String
    ) throws -> String {
        if !forceList, items.count == 1 {
            return try formatItem(items[0])
        }
        return "[\(try items.map { try formatItem($0) }.joined(separator: ", "))]"
    }

    private func propertyListEditOperationForLegacyAuthoredField(
        _ spec: USDLayerSpec,
        valueFieldName: String?
    ) throws -> String? {
        guard valueFieldName == "connectionPaths" || valueFieldName == "targetPaths" else {
            return nil
        }
        guard case .pathListOperation? = spec.fields[valueFieldName ?? ""] else {
            return try propertyListEditOperation(for: spec)
        }
        return nil
    }

    private func propertyListEditOperation(for spec: USDLayerSpec) throws -> String? {
        guard let value = spec.fields["listEditOperation"]?.authoredText else {
            return nil
        }
        guard value == "delete"
            || value == "add"
            || value == "prepend"
            || value == "append"
            || value == "reorder" else {
            throw USDError.invalidData("USDA property listEditOperation contains invalid value \(value).")
        }
        return value
    }

    private func formattedAssignmentValue(_ value: String, indentLevel: Int) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else {
            return value
        }
        let commonIndent = commonLeadingWhitespaceCount(in: lines.dropFirst())
        var normalizedLines = [String(lines[0])]
        for line in lines.dropFirst() {
            let strippedLine = line.dropFirst(min(commonIndent, line.count))
            normalizedLines.append("\(indentation(indentLevel))\(strippedLine)")
        }
        return normalizedLines.joined(separator: "\n")
    }

    private func commonLeadingWhitespaceCount<S: Sequence>(in lines: S) -> Int where S.Element == Substring {
        var commonIndent: Int?
        for line in lines {
            guard line.contains(where: { !$0.isWhitespace }) else {
                continue
            }
            let count = line.prefix { $0 == " " || $0 == "\t" }.count
            commonIndent = min(commonIndent ?? count, count)
        }
        return commonIndent ?? 0
    }

    private func parentPrimPath(for path: String) -> String {
        guard path.hasPrefix("/") else {
            return ""
        }
        guard let lastSlash = path.lastIndex(of: "/"), lastSlash != path.startIndex else {
            return ""
        }
        return String(path[..<lastSlash])
    }

    private func propertyParentPrimPath(for path: String) -> String {
        guard let dotIndex = path.lastIndex(of: ".") else {
            return ""
        }
        return String(path[..<dotIndex])
    }

    private func propertyPath(parentPrimPath: String, propertyName: String) -> String {
        "\(parentPrimPath).\(propertyName)"
    }

    private func primName(for path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private func propertyName(for path: String) -> String {
        guard let dotIndex = path.lastIndex(of: ".") else {
            return path
        }
        return String(path[path.index(after: dotIndex)...])
    }

    private func variantSetParentPrimPath(for path: String) -> String {
        guard let openBrace = path.lastIndex(of: "{") else {
            return ""
        }
        return String(path[..<openBrace])
    }

    private func variantSetName(for path: String) -> String {
        guard let openBrace = path.lastIndex(of: "{"),
              let closeBrace = path.lastIndex(of: "}") else {
            return ""
        }
        return String(path[path.index(after: openBrace)..<closeBrace])
    }

    private func variantSetPath(forVariantPath path: String) -> String {
        guard let openBrace = path.lastIndex(of: "{"),
              let equals = path.lastIndex(of: "=") else {
            return ""
        }
        return "\(path[..<openBrace]){\(path[path.index(after: openBrace)..<equals])}"
    }

    private func variantName(for path: String) -> String {
        guard let equals = path.lastIndex(of: "="),
              let closeBrace = path.lastIndex(of: "}") else {
            return ""
        }
        return String(path[path.index(after: equals)..<closeBrace])
    }

    private func specifierKeyword(_ specifier: SdfSpecifier?) throws -> String {
        switch specifier {
        case .none, .def:
            "def"
        case .over:
            "over"
        case .class:
            "class"
        case .unknown(let payload):
            throw USDError.invalidData("USDA cannot write unknown prim specifier payload \(payload).")
        }
    }

    private func indentation(_ level: Int) -> String {
        String(repeating: "    ", count: level)
    }

    private func quoted(_ value: String) -> String {
        SdfFieldValue.quoted(value)
    }

    private func referenceText(_ reference: SdfReference) throws -> String {
        let suffix = try referenceMetadataSuffix(layerOffset: reference.layerOffset, customData: reference.customData)
        return "\(assetReferenceText(assetPath: reference.assetPath, primPath: reference.primPath))\(suffix)"
    }

    private func payloadText(_ payload: SdfPayload) -> String {
        "\(assetReferenceText(assetPath: payload.assetPath, primPath: payload.primPath))\(assetReferenceMetadataSuffix(layerOffset: payload.layerOffset))"
    }

    private func assetReferenceText(assetPath: String, primPath: SdfPath?) -> String {
        if let primPath {
            return "\(assetPathText(assetPath))<\(primPath.rawValue)>"
        }
        return assetPathText(assetPath)
    }

    private func assetPathText(_ assetPath: String) -> String {
        SdfFieldValue.assetPathText(assetPath)
    }

    private func referenceMetadataSuffix(
        layerOffset: SdfLayerOffset,
        customData: [String: SdfFieldValue]
    ) throws -> String {
        var parts = layerOffsetMetadataParts(layerOffset)
        if !customData.isEmpty {
            let entries = try customData.keys.sorted().map { key in
                try customDataEntryText(name: key, value: customData[key] ?? .unmaterializedValue)
            }
            parts.append("customData = { \(entries.joined(separator: "; ")) }")
        }
        guard !parts.isEmpty else {
            return ""
        }
        return " (\(parts.joined(separator: "; ")))"
    }

    private func assetReferenceMetadataSuffix(layerOffset: SdfLayerOffset) -> String {
        let parts = layerOffsetMetadataParts(layerOffset)
        guard !parts.isEmpty else {
            return ""
        }
        return " (\(parts.joined(separator: "; ")))"
    }

    private func layerOffsetMetadataParts(_ layerOffset: SdfLayerOffset) -> [String] {
        guard !layerOffset.isIdentity else {
            return []
        }
        return [
            "offset = \(formatDouble(layerOffset.offset))",
            "scale = \(formatDouble(layerOffset.scale))",
        ]
    }

    private func customDataEntryText(name: String, value: SdfFieldValue) throws -> String {
        try SdfFieldValue.usdaDictionaryEntryText(name: name, value: value)
    }

    private func formatDouble(_ value: Double) -> String {
        SdfFieldValue.doubleText(value)
    }

    private func intArray(_ values: [Int]) -> String {
        "[\(values.map(String.init).joined(separator: ", "))]"
    }

    private func point3Array(_ values: [USDPoint3D]) -> String {
        "[\(values.map { "(\(formatDouble($0.x)), \(formatDouble($0.y)), \(formatDouble($0.z)))" }.joined(separator: ", "))]"
    }

    private func lastPathComponent(_ path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }

    private func validateScene(_ scene: USDScene) throws {
        guard scene.metersPerUnit.isFinite, scene.metersPerUnit > 0 else {
            throw USDError.invalidData("USDA scene metersPerUnit must be a positive finite value.")
        }
        for mesh in scene.meshes {
            try USDMesh.validateTopology(
                pointCount: mesh.points.count,
                faceVertexCounts: mesh.faceVertexCounts,
                faceVertexIndices: mesh.faceVertexIndices
            )
            for point in mesh.points + mesh.normals + (mesh.extent ?? []) {
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                    throw USDError.invalidData("USDA scene mesh contains a non-finite point.")
                }
            }
        }
    }

    private func indentedBlock(_ body: String, level: Int) -> String {
        let indent = indentation(level)
        return body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(indent)\($0)" }
            .joined(separator: "\n") + "\n"
    }
}

/// Pre-grouped lookups over a layer's specs, built in a single pass before
/// writing. Resolving children, properties, and variants by filtering the
/// full spec array once per spec is quadratic on large layers.
private struct USDAWriterSpecIndex {
    let childPrimSpecsByParentPath: [String: [USDLayerSpec]]
    let propertySpecsByOwnerPath: [String: [USDLayerSpec]]
    let variantSetSpecsByParentPrimPath: [String: [USDLayerSpec]]
    let variantSpecsByVariantSetPath: [String: [USDLayerSpec]]

    func childPrimSpecs(forParentPath path: String) -> [USDLayerSpec] {
        childPrimSpecsByParentPath[path] ?? []
    }

    func propertySpecs(forOwnerPath path: String) -> [USDLayerSpec] {
        propertySpecsByOwnerPath[path] ?? []
    }

    func variantSetSpecs(forParentPrimPath path: String) -> [USDLayerSpec] {
        variantSetSpecsByParentPrimPath[path] ?? []
    }

    func variantSpecs(forVariantSetPath path: String) -> [USDLayerSpec] {
        variantSpecsByVariantSetPath[path] ?? []
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
