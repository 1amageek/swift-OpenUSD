import Foundation

public struct USDAReader: USDSceneReader {
    public init() {}

    public func read(from data: Data) throws -> USDScene {
        try read(from: data, options: .default)
    }

    public func read(from data: Data, options: USDReadingOptions) throws -> USDScene {
        guard let text = String(data: data, encoding: .utf8) else {
            throw USDImportError.invalidData("USDA data is not UTF-8.")
        }
        return try read(from: text, options: options)
    }

    public func readLayer(from data: Data) throws -> USDALayer {
        guard let text = String(data: data, encoding: .utf8) else {
            throw USDImportError.invalidData("USDA data is not UTF-8.")
        }
        return try readLayer(from: text)
    }

    public func read(from text: String) throws -> USDScene {
        try read(from: text, options: .default)
    }

    public func read(from text: String, options: USDReadingOptions) throws -> USDScene {
        let text = try readerVisibleText(from: text)
        try validateSignature(in: text)
        try validateTopLevelSyntax(in: text)
        try validatePrimAttributeSyntax(in: text)
        try validateUniqueSiblingPrimPaths(in: text, parentPrimPath: "")
        if let timeCode = options.timeCode, !timeCode.isFinite {
            throw USDImportError.invalidData("USDA requested timeCode must be finite.")
        }
        let metersPerUnit = try parseRequiredDouble(named: "metersPerUnit", in: text)
        guard metersPerUnit.isFinite, metersPerUnit > 0 else {
            throw USDImportError.invalidData("USDA metersPerUnit must be a positive finite value.")
        }
        let upAxis = try parseUpAxis(in: text)
        let defaultPrim = try parseOptionalString(named: "defaultPrim", in: text)
        let meshes = try parseMeshes(in: text, options: options)
        guard !meshes.isEmpty else {
            throw USDImportError.invalidData("USDA scene contains no Mesh prims.")
        }
        return USDScene(defaultPrim: defaultPrim, metersPerUnit: metersPerUnit, upAxis: upAxis, meshes: meshes)
    }

    public func readLayer(from text: String) throws -> USDALayer {
        let text = try readerVisibleText(from: text)
        try validateSignature(in: text)
        try validateTopLevelSyntax(in: text)
        try validatePrimAttributeSyntax(in: text)
        let specs = try parseLayerSpecs(in: text)
        try validateUniqueSiblingPrimPaths(in: text, parentPrimPath: "")
        let metadataBody = try layerMetadataBody(in: text)
        let defaultPrim = try metadataBody.flatMap { try parseOptionalString(named: "defaultPrim", in: $0) }
        let metersPerUnit = try metadataBody.flatMap { try parseOptionalDouble(named: "metersPerUnit", in: $0) }
        if let metersPerUnit, (!metersPerUnit.isFinite || metersPerUnit <= 0) {
            throw USDImportError.invalidData("USDA metersPerUnit must be a positive finite value.")
        }
        let upAxisToken = try metadataBody.flatMap { try parseOptionalString(named: "upAxis", in: $0) }
        let upAxis: USDUpAxis?
        if let upAxisToken {
            guard let parsed = USDUpAxis(rawValue: upAxisToken) else {
                throw USDImportError.invalidData("Unsupported USDA upAxis \(upAxisToken).")
            }
            upAxis = parsed
        } else {
            upAxis = nil
        }
        return USDALayer(
            defaultPrim: defaultPrim,
            metersPerUnit: metersPerUnit,
            upAxis: upAxis,
            composition: try parseLayerComposition(in: text, metadataBody: metadataBody),
            specs: specs,
            primTransforms: try parsePrimTransforms(in: text)
        )
    }

    public func readComposition(from data: Data) throws -> USDLayerComposition {
        try readLayer(from: data).composition
    }

    private func validateSignature(in text: String) throws {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#usda") else {
            throw USDImportError.invalidData("USDA data is missing the #usda signature.")
        }
    }

    private func validateTopLevelSyntax(in text: String) throws {
        var cursor = topLevelSyntaxStart(in: text)
        var hasReadMetadata = false
        while true {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex else {
                return
            }
            if text[cursor] == ";" {
                cursor = text.index(after: cursor)
                continue
            }
            if !hasReadMetadata, text[cursor] == "(" {
                let metadataEnd = try matchingParenthesis(startingAt: cursor, in: text)
                cursor = text.index(after: metadataEnd)
                hasReadMetadata = true
                continue
            }
            if primDeclarationKeyword(at: cursor, in: text) != nil {
                let prim = try parsePrim(at: cursor, in: text)
                cursor = prim.fullRange.upperBound
                continue
            }
            throw USDImportError.invalidData("USDA contains unexpected top-level syntax.")
        }
    }

    private func topLevelSyntaxStart(in text: String) -> String.Index {
        guard let signatureRange = text.range(of: "#usda") else {
            return text.startIndex
        }
        guard let lineEnd = text[signatureRange.upperBound...].firstIndex(of: "\n") else {
            return text.endIndex
        }
        return text.index(after: lineEnd)
    }

    private func skipWhitespaceAndLineComments(in text: String, index: inout String.Index) {
        while index < text.endIndex {
            skipWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == "#" else {
                return
            }
            skipLineComment(in: text, index: &index)
        }
    }

    private func validatePrimAttributeSyntax(in text: String) throws {
        let prims = try parseDirectPrims(in: text)
        for prim in prims {
            let directAttributeText = try directAttributeText(from: prim.body)
            try validateBoolMetadata(named: "hidden", in: prim.metadataBody)
            try validateBoolMetadata(named: "hidden", in: directAttributeText)
            try validateCompositionListEdits(in: prim.metadataBody)
            try validateScalarAssignments(in: directAttributeText)
            try validatePrimAttributeSyntax(in: prim.body)
        }
    }

    private func validateBoolMetadata(named name: String, in text: String) throws {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            guard token(name, matchesAt: cursor, in: text) else {
                cursor = text.index(after: cursor)
                continue
            }
            var valueCursor = text.index(cursor, offsetBy: name.count)
            skipWhitespace(in: text, index: &valueCursor)
            guard valueCursor < text.endIndex, text[valueCursor] == "=" else {
                cursor = text.index(after: cursor)
                continue
            }
            valueCursor = text.index(after: valueCursor)
            skipWhitespace(in: text, index: &valueCursor)
            let valueStart = valueCursor
            while valueCursor < text.endIndex {
                let character = text[valueCursor]
                if character.isWhitespace || character == ";" || character == "," || character == ")" {
                    break
                }
                valueCursor = text.index(after: valueCursor)
            }
            let value = String(text[valueStart..<valueCursor])
            guard value == "true" || value == "false" else {
                throw USDImportError.invalidData("USDA \(name) metadata contains invalid bool value \(value).")
            }
            cursor = valueCursor
        }
    }

    private func validateCompositionListEdits(in text: String) throws {
        try validateBracketedListEdits(forField: "references", in: text)
        try validateBracketedListEdits(forField: "payload", in: text)
    }

    private func validateBracketedListEdits(forField fieldName: String, in text: String) throws {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            guard let qualifier = compositionListEditQualifier(at: cursor, in: text) else {
                cursor = text.index(after: cursor)
                continue
            }
            var fieldCursor = text.index(cursor, offsetBy: qualifier.count)
            skipWhitespace(in: text, index: &fieldCursor)
            guard token(fieldName, matchesAt: fieldCursor, in: text) else {
                cursor = text.index(after: cursor)
                continue
            }
            var valueCursor = text.index(fieldCursor, offsetBy: fieldName.count)
            skipWhitespace(in: text, index: &valueCursor)
            guard valueCursor < text.endIndex, text[valueCursor] == "=" else {
                cursor = text.index(after: cursor)
                continue
            }
            valueCursor = text.index(after: valueCursor)
            skipWhitespace(in: text, index: &valueCursor)
            guard valueCursor < text.endIndex, text[valueCursor] == "[" else {
                throw USDImportError.invalidData("USDA \(fieldName) \(qualifier) list-edit must use a bracketed list value.")
            }
            let closeBracket = try matchingBracket(startingAt: valueCursor, in: text)
            cursor = text.index(after: closeBracket)
        }
    }

    private func compositionListEditQualifier(at index: String.Index, in text: String) -> String? {
        for qualifier in ["add", "reorder"] {
            guard token(qualifier, matchesAt: index, in: text) else {
                continue
            }
            return qualifier
        }
        return nil
    }

    private func token(_ token: String, matchesAt index: String.Index, in text: String) -> Bool {
        guard text[index...].hasPrefix(token),
              let tokenEnd = text.index(index, offsetBy: token.count, limitedBy: text.endIndex) else {
            return false
        }
        let hasLeadingBoundary: Bool
        if index == text.startIndex {
            hasLeadingBoundary = true
        } else {
            let previous = text[text.index(before: index)]
            hasLeadingBoundary = !isIdentifierCharacter(previous)
        }
        let hasTrailingBoundary = tokenEnd == text.endIndex || !isIdentifierCharacter(text[tokenEnd])
        return hasLeadingBoundary && hasTrailingBoundary
    }

    private func validateUniqueSiblingPrimPaths(
        in text: String,
        parentPrimPath: String
    ) throws {
        var seenPaths: Set<String> = []
        let prims = try parseDirectPrims(in: text)
        for prim in prims {
            let path = primPath(for: prim, parentPrimPath: parentPrimPath)
            guard seenPaths.insert(path).inserted else {
                throw USDImportError.invalidData("USDA contains duplicate prim path \(path).")
            }
            try validateUniqueSiblingPrimPaths(
                in: prim.body,
                parentPrimPath: path
            )
        }
    }

    private func validateScalarAssignments(in text: String) throws {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            guard let valueType = scalarAttributeType(at: cursor, in: text) else {
                cursor = text.index(after: cursor)
                continue
            }
            try validateScalarAssignment(type: valueType, startingAt: cursor, in: text)
            cursor = text.index(cursor, offsetBy: valueType.count)
        }
    }

    private func validateScalarAssignment(type valueType: String, startingAt typeIndex: String.Index, in text: String) throws {
        var cursor = text.index(typeIndex, offsetBy: valueType.count)
        skipWhitespace(in: text, index: &cursor)
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "=" || character == "(" || character == "\n" || character == "\r" {
                break
            }
            cursor = text.index(after: cursor)
        }
        skipWhitespace(in: text, index: &cursor)
        if cursor < text.endIndex, text[cursor] == "(" {
            let metadataEnd = try matchingParenthesis(startingAt: cursor, in: text)
            cursor = text.index(after: metadataEnd)
            skipWhitespace(in: text, index: &cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "=" else {
            return
        }
        cursor = text.index(after: cursor)
        skipWhitespace(in: text, index: &cursor)
        let valueStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == ";" || character == "," || character == ")" || character == "]" || character == "}" {
                break
            }
            cursor = text.index(after: cursor)
        }
        let value = String(text[valueStart..<cursor])
        switch valueType {
        case "bool":
            guard ["true", "false", "0", "1", "None"].contains(value) else {
                throw USDImportError.invalidData("USDA bool attribute contains invalid value \(value).")
            }
        case "int":
            guard value == "None" || Int(value) != nil else {
                throw USDImportError.invalidData("USDA int attribute contains invalid value \(value).")
            }
        case "string":
            guard value == "None" || value.first == "\"" || value.first == "'" else {
                throw USDImportError.invalidData("USDA string attribute contains invalid value \(value).")
            }
        default:
            return
        }
    }

    private func scalarAttributeType(at index: String.Index, in text: String) -> String? {
        for keyword in ["bool", "int", "string"] {
            guard scalarAttributeType(keyword, matchesAt: index, in: text) else {
                continue
            }
            return keyword
        }
        return nil
    }

    private func scalarAttributeType(_ keyword: String, matchesAt index: String.Index, in text: String) -> Bool {
        guard text[index...].hasPrefix(keyword),
              let keywordEnd = text.index(index, offsetBy: keyword.count, limitedBy: text.endIndex) else {
            return false
        }
        let hasLeadingBoundary: Bool
        if index == text.startIndex {
            hasLeadingBoundary = true
        } else {
            let previous = text[text.index(before: index)]
            hasLeadingBoundary = previous.isWhitespace || previous == ";" || previous == "{" || previous == "("
        }
        let hasTrailingBoundary = keywordEnd == text.endIndex || text[keywordEnd].isWhitespace
        return hasLeadingBoundary && hasTrailingBoundary
    }

    private func readerVisibleText(from text: String) throws -> String {
        guard let endTokenIndex = try endTokenIndex(in: text) else {
            return text
        }
        return String(text[..<endTokenIndex])
    }

    private func endTokenIndex(in text: String) throws -> String.Index? {
        let endToken = "__END__"
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &index)
                continue
            }
            if text[index...].hasPrefix(endToken),
               hasEndTokenLeadingBoundary(at: index, in: text),
               let afterEndToken = text.index(index, offsetBy: endToken.count, limitedBy: text.endIndex),
               hasEndTokenTrailingBoundary(at: afterEndToken, in: text) {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func hasEndTokenLeadingBoundary(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else {
            return true
        }
        return !isIdentifierCharacter(text[text.index(before: index)])
    }

    private func hasEndTokenTrailingBoundary(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else {
            return true
        }
        return !isIdentifierCharacter(text[index])
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        String(character).unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x5f || scalar.properties.isXIDContinue
        }
    }

    private func layerMetadataBody(in text: String) throws -> String? {
        guard let signatureRange = text.range(of: "#usda") else {
            return nil
        }
        guard let lineEnd = text[signatureRange.upperBound...].firstIndex(of: "\n") else {
            return nil
        }
        var cursor = text.index(after: lineEnd)
        while cursor < text.endIndex {
            skipWhitespace(in: text, index: &cursor)
            if cursor < text.endIndex, text[cursor] == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            break
        }

        guard cursor < text.endIndex, text[cursor] == "(" else {
            return nil
        }
        let metadataEnd = try matchingParenthesis(startingAt: cursor, in: text)
        return String(text[text.index(after: cursor)..<metadataEnd])
    }

    private func parseLayerComposition(in text: String, metadataBody: String?) throws -> USDLayerComposition {
        var composition = USDLayerComposition()
        if let metadataBody {
            composition.sublayers = try parseSublayers(forField: "subLayers", in: metadataBody)
        }
        let prims = try parseDirectPrims(in: text)
        try appendCompositionArcs(from: prims, parentPrimPath: "", to: &composition)
        return composition
    }

    private func appendCompositionArcs(
        from prims: [USDAPrim],
        parentPrimPath: String,
        to composition: inout USDLayerComposition
    ) throws {
        for prim in prims {
            let sitePrimPath = primPath(for: prim, parentPrimPath: parentPrimPath)
            composition.references.append(contentsOf: try parseCompositionArcs(
                forField: "references",
                in: prim.metadataBody,
                sitePrimPath: sitePrimPath
            ))
            composition.payloads.append(contentsOf: try parseCompositionArcs(
                forField: "payload",
                in: prim.metadataBody,
                sitePrimPath: sitePrimPath
            ))
            let childPrims = try parseDirectPrims(in: prim.body)
            try appendCompositionArcs(from: childPrims, parentPrimPath: sitePrimPath, to: &composition)
        }
    }

    private func parseMeshes(in text: String, options: USDReadingOptions) throws -> [USDMesh] {
        try parseMeshes(in: text, options: options, inheritedTransform: .identity, parentPrimPath: "")
    }

    private func parseLayerSpecs(in text: String) throws -> [USDLayerSpec] {
        var specs = [
            USDLayerSpec(path: "/", specType: .pseudoRoot)
        ]
        specs.append(contentsOf: try parseLayerSpecs(
            from: parseDirectPrims(in: text),
            parentPrimPath: ""
        ))
        return specs
    }

    private func parseLayerSpecs(from prims: [USDAPrim], parentPrimPath: String) throws -> [USDLayerSpec] {
        var specs: [USDLayerSpec] = []
        for prim in prims {
            let path = primPath(for: prim, parentPrimPath: parentPrimPath)
            var fieldNames = ["specifier"]
            if prim.typeName != nil {
                fieldNames.append("typeName")
            }
            specs.append(USDLayerSpec(
                path: path,
                specType: .prim,
                specifier: prim.specifier,
                typeName: prim.typeName,
                fieldNames: fieldNames
            ))
            specs.append(contentsOf: try parseLayerSpecs(
                from: parseDirectPrims(in: prim.body),
                parentPrimPath: path
            ))
        }
        return specs
    }

    private func parsePrimTransforms(in text: String) throws -> [String: USDTransformMatrix4x4] {
        try parsePrimTransforms(in: text, inheritedTransform: .identity, parentPrimPath: "")
    }

    private func parsePrimTransforms(
        in text: String,
        inheritedTransform: USDTransformMatrix4x4,
        parentPrimPath: String
    ) throws -> [String: USDTransformMatrix4x4] {
        var primTransforms: [String: USDTransformMatrix4x4] = [:]
        let prims = try parseDirectPrims(in: text)
        for prim in prims {
            let primPath = primPath(for: prim, parentPrimPath: parentPrimPath)
            let directBody = try directAttributeText(from: prim.body)
            let localTransform = try parseLocalTransform(in: directBody)
            let primTransform = localTransform.resetsParentStack
                ? localTransform.matrix
                : localTransform.matrix.concatenating(inheritedTransform)
            primTransforms[primPath] = primTransform
            let childTransforms = try parsePrimTransforms(
                in: prim.body,
                inheritedTransform: primTransform,
                parentPrimPath: primPath
            )
            primTransforms.merge(childTransforms) { _, new in new }
        }
        return primTransforms
    }

    private func parseMeshes(
        in text: String,
        options: USDReadingOptions,
        inheritedTransform: USDTransformMatrix4x4,
        parentPrimPath: String
    ) throws -> [USDMesh] {
        var meshes: [USDMesh] = []
        let prims = try parseDirectPrims(in: text)
        for prim in prims {
            let primPath = primPath(for: prim, parentPrimPath: parentPrimPath)
            let directBody = try directAttributeText(from: prim.body)
            let localTransform = try parseLocalTransform(in: directBody)
            let primTransform = localTransform.resetsParentStack
                ? localTransform.matrix
                : localTransform.matrix.concatenating(inheritedTransform)
            if prim.typeName == "Mesh" {
                meshes.append(try materializeMesh(
                    prim: prim,
                    primPath: primPath,
                    directBody: directBody,
                    options: options,
                    transform: primTransform
                ))
            }
            meshes.append(contentsOf: try parseMeshes(
                in: prim.body,
                options: options,
                inheritedTransform: primTransform,
                parentPrimPath: primPath
            ))
        }
        return meshes
    }

    private func materializeMesh(
        prim: USDAPrim,
        primPath: String,
        directBody: String,
        options: USDReadingOptions,
        transform: USDTransformMatrix4x4
    ) throws -> USDMesh {
        let points = try parsePointArray(named: "points", in: directBody, options: options)
        let transformedPoints = try points.map { try transform.transform($0) }
        let counts = try parseIntArray(named: "faceVertexCounts", in: directBody)
        let indices = try parseIntArray(named: "faceVertexIndices", in: directBody)
        let normals = try parseOptionalPointArray(named: "normals", in: directBody) ?? []
        let transformedNormals = try normals.map { try transform.transformNormal($0) }
        let normalsInterpolation = try parseOptionalAttributeMetadataString(
            attributeName: "normals",
            metadataName: "interpolation",
            in: directBody
        )
        let orientation = try parseOptionalOrientation(in: directBody)
        let subdivisionScheme = try parseOptionalString(named: "subdivisionScheme", in: directBody)
        let textureCoordinates = try parseOptionalTextureCoordinates(in: directBody)
        let displayColor = try parseOptionalDisplayColor(in: directBody)
        let displayOpacity = try parseOptionalDisplayOpacity(in: directBody)
        if let textureCoordinates {
            try textureCoordinates.validate(pointCount: transformedPoints.count, faceVertexCounts: counts)
        }
        if let displayColor {
            try displayColor.validate(pointCount: transformedPoints.count, faceVertexCounts: counts)
        }
        if let displayOpacity {
            try displayOpacity.validate(pointCount: transformedPoints.count, faceVertexCounts: counts)
        }
        let extent = try parseOptionalPointArray(named: "extent", in: directBody)
        if let extent, extent.count != 2 {
            throw USDImportError.invalidData("USDA extent must contain exactly two points.")
        }
        return USDMesh(
            name: prim.name,
            primPath: primPath,
            points: transformedPoints,
            faceVertexCounts: counts,
            faceVertexIndices: indices,
            normals: transformedNormals,
            normalsInterpolation: normalsInterpolation,
            orientation: orientation,
            subdivisionScheme: subdivisionScheme,
            textureCoordinates: textureCoordinates,
            displayColor: displayColor,
            displayOpacity: displayOpacity,
            extent: extent
        )
    }

    private func primPath(for prim: USDAPrim, parentPrimPath: String) -> String {
        guard let name = prim.name else {
            return parentPrimPath.isEmpty ? "/" : parentPrimPath
        }
        if parentPrimPath.isEmpty || parentPrimPath == "/" {
            return "/\(name)"
        }
        return "\(parentPrimPath)/\(name)"
    }

    private func parseDirectPrims(in text: String) throws -> [USDAPrim] {
        var prims: [USDAPrim] = []
        var searchIndex = text.startIndex
        while let declarationIndex = try nextDirectPrimDeclaration(in: text, from: searchIndex) {
            let prim = try parsePrim(at: declarationIndex, in: text)
            prims.append(prim)
            searchIndex = prim.fullRange.upperBound
        }
        return prims
    }

    private func directAttributeText(from text: String) throws -> String {
        var output = ""
        var searchIndex = text.startIndex
        while let declarationIndex = try nextDirectPrimDeclaration(in: text, from: searchIndex) {
            output += String(text[searchIndex..<declarationIndex])
            let prim = try parsePrim(at: declarationIndex, in: text)
            searchIndex = prim.fullRange.upperBound
        }
        output += String(text[searchIndex..<text.endIndex])
        return output
    }

    private func nextDirectPrimDeclaration(in text: String, from startIndex: String.Index) throws -> String.Index? {
        var index = startIndex
        var braceDepth = 0
        var bracketDepth = 0
        var parenthesisDepth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &index)
                continue
            }
            if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if braceDepth == 0,
                      bracketDepth == 0,
                      parenthesisDepth == 0,
                      primDeclarationKeyword(at: index, in: text) != nil {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func parsePrim(at declarationIndex: String.Index, in text: String) throws -> USDAPrim {
        guard let keyword = primDeclarationKeyword(at: declarationIndex, in: text) else {
            throw USDImportError.invalidData("USDA prim declaration has an unsupported specifier.")
        }
        let specifier = try primSpecifier(for: keyword)
        var cursor = text.index(declarationIndex, offsetBy: keyword.count)
        try skipPrimDeclarationWhitespace(in: text, index: &cursor)
        var typeName: String?
        let name: String?
        if cursor < text.endIndex, text[cursor] == "\"" {
            let quoted = try parseQuotedString(startingAt: cursor, in: text)
            name = quoted.value
            cursor = quoted.endIndex
        } else {
            let typeStart = cursor
            while cursor < text.endIndex,
                  !text[cursor].isWhitespace,
                  text[cursor] != "\"",
                  text[cursor] != "(",
                  text[cursor] != "{" {
                cursor = text.index(after: cursor)
            }
            guard typeStart < cursor else {
                throw USDImportError.invalidData("USDA prim declaration is missing a type name.")
            }
            typeName = String(text[typeStart..<cursor])
            try skipPrimDeclarationWhitespace(in: text, index: &cursor)
            guard cursor < text.endIndex, text[cursor] == "\"" else {
                throw USDImportError.invalidData("USDA prim declaration is missing a quoted name.")
            }
            let quoted = try parseQuotedString(startingAt: cursor, in: text)
            name = quoted.value
            cursor = quoted.endIndex
        }
        if let name {
            try validatePrimName(name)
        }
        skipWhitespace(in: text, index: &cursor)
        let metadataBody: String
        if cursor < text.endIndex, text[cursor] == "(" {
            let metadataEnd = try matchingParenthesis(startingAt: cursor, in: text)
            metadataBody = String(text[text.index(after: cursor)..<metadataEnd])
            cursor = text.index(after: metadataEnd)
        } else {
            metadataBody = ""
        }

        guard let openBrace = text[cursor...].firstIndex(of: "{") else {
            throw USDImportError.invalidData("USDA prim is missing an opening brace.")
        }
        let closeBrace = try matchingBrace(startingAt: openBrace, in: text)
        let body = String(text[text.index(after: openBrace)..<closeBrace])
        return USDAPrim(
            specifier: specifier,
            typeName: typeName,
            name: name,
            metadataBody: metadataBody,
            body: body,
            fullRange: declarationIndex..<text.index(after: closeBrace)
        )
    }

    private func primSpecifier(for keyword: String) throws -> USDPrimSpecifier {
        switch keyword {
        case "def":
            return .def
        case "over":
            return .over
        case "class":
            return .class
        default:
            throw USDImportError.invalidData("USDA prim declaration has an unsupported specifier.")
        }
    }

    private func parseQuotedString(
        startingAt quoteStart: String.Index,
        in text: String
    ) throws -> (value: String, endIndex: String.Index) {
        guard quoteStart < text.endIndex, text[quoteStart] == "\"" else {
            throw USDImportError.invalidData("USDA string is missing an opening quote.")
        }
        guard let quoteEnd = text[text.index(after: quoteStart)...].firstIndex(of: "\"") else {
            throw USDImportError.invalidData("USDA string is unterminated.")
        }
        return (
            String(text[text.index(after: quoteStart)..<quoteEnd]),
            text.index(after: quoteEnd)
        )
    }

    private func validatePrimName(_ name: String) throws {
        guard let firstScalar = name.unicodeScalars.first else {
            throw USDImportError.invalidData("USDA prim name is not a valid identifier.")
        }
        guard firstScalar.value == 0x5f || firstScalar.properties.isXIDStart else {
            throw USDImportError.invalidData("USDA prim name \(name) is not a valid identifier.")
        }
        for scalar in name.unicodeScalars.dropFirst() {
            guard scalar.properties.isXIDContinue else {
                throw USDImportError.invalidData("USDA prim name \(name) is not a valid identifier.")
            }
        }
    }

    private func primDeclarationKeyword(at index: String.Index, in text: String) -> String? {
        let keywords = ["class", "over", "def"]
        guard let keyword = keywords.first(where: { text[index...].hasPrefix($0) }) else {
            return nil
        }
        guard let keywordEnd = text.index(index, offsetBy: keyword.count, limitedBy: text.endIndex) else {
            return nil
        }
        let hasLeadingBoundary: Bool
        if index == text.startIndex {
            hasLeadingBoundary = true
        } else {
            let previous = text[text.index(before: index)]
            hasLeadingBoundary = previous.isWhitespace || previous == "{" || previous == "}" || previous == ";"
        }
        let hasTrailingBoundary = keywordEnd == text.endIndex || text[keywordEnd].isWhitespace
        return hasLeadingBoundary && hasTrailingBoundary ? keyword : nil
    }

    private func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private func skipPrimDeclarationWhitespace(in text: String, index: inout String.Index) throws {
        while index < text.endIndex, text[index].isWhitespace {
            if text[index].isNewline {
                throw USDImportError.invalidData("USDA prim declaration cannot split specifier, type, and name across lines.")
            }
            index = text.index(after: index)
        }
    }

    private func skipLineComment(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index] != "\n" {
            index = text.index(after: index)
        }
    }

    private func parseRequiredDouble(named name: String, in text: String) throws -> Double {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([-+0-9.eE]+)"
        let match = try firstMatch(pattern: pattern, in: text)
        guard let match else {
            throw USDImportError.missingRequiredField(name)
        }
        guard let value = Double(match) else {
            throw USDImportError.invalidData("USDA \(name) is not a valid number.")
        }
        return value
    }

    private func parseUpAxis(in text: String) throws -> USDUpAxis {
        guard let value = try parseOptionalString(named: "upAxis", in: text) else {
            return .y
        }
        guard let axis = USDUpAxis(rawValue: value) else {
            throw USDImportError.invalidData("Unsupported USDA upAxis \(value).")
        }
        return axis
    }

    private func parseOptionalOrientation(in text: String) throws -> USDOrientation? {
        guard let value = try parseOptionalString(named: "orientation", in: text) else {
            return nil
        }
        guard let orientation = USDOrientation(rawValue: value) else {
            throw USDImportError.invalidData("Unsupported USDA orientation \(value).")
        }
        return orientation
    }

    private func parseLocalTransform(in text: String) throws -> USDALocalTransform {
        guard let xformOpOrder = try parseOptionalTokenArray(named: "xformOpOrder", in: text) else {
            return USDALocalTransform(matrix: .identity, resetsParentStack: false)
        }
        var transform = USDTransformMatrix4x4.identity
        var resetsParentStack = false
        for opName in xformOpOrder.reversed() {
            if opName == "!resetXformStack!" {
                resetsParentStack = true
                break
            }
            let orderedOp = orderedXformOperationName(from: opName)
            guard attributeNameRange(named: orderedOp.attributeName, in: text) != nil else {
                continue
            }
            let opTransform = try self.transform(forXformOp: orderedOp.attributeName, in: text)
            let effectiveTransform = orderedOp.isInverted ? try opTransform.inverted() : opTransform
            transform = transform.concatenating(effectiveTransform)
        }
        return USDALocalTransform(matrix: transform, resetsParentStack: resetsParentStack)
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

    private func transform(forXformOp opName: String, in text: String) throws -> USDTransformMatrix4x4 {
        guard let operationType = xformOperationType(from: opName) else {
            throw USDImportError.invalidData("USDA xform op \(opName) is malformed.")
        }
        switch operationType {
        case "translate":
            return .translation(try parseRequiredVector3(named: opName, in: text))
        case "translateX":
            return .translation(USDTransformVector3D(x: try parseRequiredScalar(named: opName, in: text), y: 0, z: 0))
        case "translateY":
            return .translation(USDTransformVector3D(x: 0, y: try parseRequiredScalar(named: opName, in: text), z: 0))
        case "translateZ":
            return .translation(USDTransformVector3D(x: 0, y: 0, z: try parseRequiredScalar(named: opName, in: text)))
        case "scale":
            return .scale(try parseRequiredVector3(named: opName, in: text))
        case "scaleX":
            return .scale(USDTransformVector3D(x: try parseRequiredScalar(named: opName, in: text), y: 1, z: 1))
        case "scaleY":
            return .scale(USDTransformVector3D(x: 1, y: try parseRequiredScalar(named: opName, in: text), z: 1))
        case "scaleZ":
            return .scale(USDTransformVector3D(x: 1, y: 1, z: try parseRequiredScalar(named: opName, in: text)))
        case "rotateX":
            return try .rotationX(angleInDegrees: parseRequiredScalar(named: opName, in: text))
        case "rotateY":
            return try .rotationY(angleInDegrees: parseRequiredScalar(named: opName, in: text))
        case "rotateZ":
            return try .rotationZ(angleInDegrees: parseRequiredScalar(named: opName, in: text))
        case "rotateXYZ", "rotateXZY", "rotateYXZ", "rotateYZX", "rotateZXY", "rotateZYX":
            let order = String(operationType.dropFirst("rotate".count))
            return try .eulerRotation(order: order, anglesInDegrees: parseRequiredVector3(named: opName, in: text))
        case "orient":
            return try parseRequiredQuaternion(named: opName, in: text).rotationMatrix()
        case "transform":
            return try parseRequiredMatrix4x4(named: opName, in: text)
        default:
            throw USDImportError.unsupportedFeature("USDA xform op \(operationType) is not supported yet.")
        }
    }

    private func xformOperationType(from opName: String) -> String? {
        let prefix = "xformOp:"
        guard opName.hasPrefix(prefix) else {
            return nil
        }
        let suffixStart = opName.index(opName.startIndex, offsetBy: prefix.count)
        return opName[suffixStart...].split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    private func parseOptionalString(named name: String, in text: String) throws -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]*)\""
        return try firstMatch(pattern: pattern, in: text)
    }

    private func parseOptionalDouble(named name: String, in text: String) throws -> Double? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([-+0-9.eE]+)"
        guard let match = try firstMatch(pattern: pattern, in: text) else {
            return nil
        }
        guard let value = Double(match) else {
            throw USDImportError.invalidData("USDA \(name) is not a valid number.")
        }
        return value
    }

    private func parseOptionalTokenArray(named name: String, in text: String) throws -> [String]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        let expression = try NSRegularExpression(pattern: "\"([^\"]*)\"")
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return expression.matches(in: body, range: range).compactMap { match in
            guard let tokenRange = Range(match.range(at: 1), in: body) else {
                return nil
            }
            return String(body[tokenRange])
        }
    }

    private func parseCompositionArcs(
        forField name: String,
        in text: String,
        sitePrimPath: String
    ) throws -> [USDCompositionArc] {
        try parseAssetReferences(forField: name, in: text).map { reference in
            USDCompositionArc(
                assetPath: reference.assetPath,
                sitePrimPath: sitePrimPath,
                targetPrimPath: reference.primPath,
                layerOffset: reference.layerOffset
            )
        }
    }

    private func parseSublayers(forField name: String, in text: String) throws -> [USDSublayer] {
        try parseAssetReferences(forField: name, in: text).map { reference in
            USDSublayer(assetPath: reference.assetPath, layerOffset: reference.layerOffset)
        }
    }

    private func parseAssetReferences(
        forField name: String,
        in text: String
    ) throws -> [(assetPath: String, primPath: String?, layerOffset: USDLayerOffset)] {
        guard let body = try compositionFieldBody(named: name, in: text) else {
            return []
        }
        return try parseAssetReferences(in: body)
    }

    private func parseAssetReferences(
        in body: String
    ) throws -> [(assetPath: String, primPath: String?, layerOffset: USDLayerOffset)] {
        var references: [(assetPath: String, primPath: String?, layerOffset: USDLayerOffset)] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard body[cursor] == "@" else {
                cursor = body.index(after: cursor)
                continue
            }
            let assetPath = try parseAssetPath(startingAt: cursor, in: body, endIndex: &cursor)
            skipWhitespace(in: body, index: &cursor)
            let primPath = try parseOptionalPrimPath(in: body, index: &cursor)
            skipWhitespace(in: body, index: &cursor)
            let layerOffset = try parseOptionalLayerOffset(in: body, index: &cursor)
            references.append((assetPath: assetPath, primPath: primPath, layerOffset: layerOffset))
        }
        return references
    }

    private func parseAssetPath(
        startingAt openDelimiter: String.Index,
        in text: String,
        endIndex: inout String.Index
    ) throws -> String {
        var cursor = text.index(after: openDelimiter)
        var assetPath = ""
        while cursor < text.endIndex {
            if text[cursor] == "@" {
                let next = text.index(after: cursor)
                if next < text.endIndex, text[next] == "@" {
                    assetPath.append("@")
                    cursor = text.index(after: next)
                    continue
                }
                endIndex = next
                guard !assetPath.isEmpty else {
                    throw USDImportError.invalidData("USDA asset path cannot be empty.")
                }
                return assetPath
            }
            assetPath.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        throw USDImportError.invalidData("USDA asset path is unterminated.")
    }

    private func parseOptionalPrimPath(in text: String, index: inout String.Index) throws -> String? {
        guard index < text.endIndex, text[index] == "<" else {
            return nil
        }
        guard let closeAngle = text[index...].firstIndex(of: ">") else {
            throw USDImportError.invalidData("USDA composition arc prim path is unterminated.")
        }
        let value = String(text[text.index(after: index)..<closeAngle])
        index = text.index(after: closeAngle)
        return value
    }

    private func parseOptionalLayerOffset(in text: String, index: inout String.Index) throws -> USDLayerOffset {
        guard index < text.endIndex, text[index] == "(" else {
            return .identity
        }
        let closeParenthesis = try matchingParenthesis(startingAt: index, in: text)
        let body = String(text[text.index(after: index)..<closeParenthesis])
        index = text.index(after: closeParenthesis)
        return try parseLayerOffset(in: body)
    }

    private func parseLayerOffset(in text: String) throws -> USDLayerOffset {
        let offset = try parseOptionalDouble(named: "offset", in: text) ?? 0
        let scale = try parseOptionalDouble(named: "scale", in: text) ?? 1
        guard offset.isFinite, scale.isFinite else {
            throw USDImportError.invalidData("USDA layer offset must contain finite values.")
        }
        return USDLayerOffset(offset: offset, scale: scale)
    }

    private func compositionFieldBody(named name: String, in text: String) throws -> String? {
        guard let nameRange = attributeNameRange(named: name, in: text),
              let equalSign = text[nameRange.upperBound...].firstIndex(of: "=") else {
            return nil
        }

        var cursor = text.index(after: equalSign)
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex else {
            return ""
        }
        if text[cursor] == "[" {
            return try bracketArrayBody(after: cursor, named: name, in: text)
        }

        var end = cursor
        while end < text.endIndex, text[end] != "\n", text[end] != "\r" {
            end = text.index(after: end)
        }
        return String(text[cursor..<end])
    }

    private func parseOptionalTextureCoordinates(in text: String) throws -> USDTextureCoordinatePrimvar? {
        guard let values = try parseOptionalPoint2Array(named: "primvars:st", in: text) else {
            return nil
        }
        let indices = try parseOptionalIntArray(named: "primvars:st:indices", in: text)
        let interpolation = try parseOptionalAttributeMetadataString(
            attributeName: "primvars:st",
            metadataName: "interpolation",
            in: text
        )
        return USDTextureCoordinatePrimvar(values: values, indices: indices, interpolation: interpolation)
    }

    private func parseOptionalDisplayColor(in text: String) throws -> USDDisplayColorPrimvar? {
        guard let values = try parseOptionalColorArray(named: "primvars:displayColor", in: text) else {
            return nil
        }
        let indices = try parseOptionalIntArray(named: "primvars:displayColor:indices", in: text)
        let interpolation = try parseOptionalAttributeMetadataString(
            attributeName: "primvars:displayColor",
            metadataName: "interpolation",
            in: text
        )
        return USDDisplayColorPrimvar(values: values, indices: indices, interpolation: interpolation)
    }

    private func parseOptionalDisplayOpacity(in text: String) throws -> USDDisplayOpacityPrimvar? {
        guard let values = try parseOptionalDoubleArray(named: "primvars:displayOpacity", in: text) else {
            return nil
        }
        let indices = try parseOptionalIntArray(named: "primvars:displayOpacity:indices", in: text)
        let interpolation = try parseOptionalAttributeMetadataString(
            attributeName: "primvars:displayOpacity",
            metadataName: "interpolation",
            in: text
        )
        return USDDisplayOpacityPrimvar(values: values, indices: indices, interpolation: interpolation)
    }

    private func parseOptionalAttributeMetadataString(
        attributeName: String,
        metadataName: String,
        in text: String
    ) throws -> String? {
        guard let nameRange = attributeNameRange(named: attributeName, in: text) else {
            return nil
        }
        guard let openBracket = text[nameRange.upperBound...].firstIndex(of: "[") else {
            return nil
        }
        let closeBracket = try matchingBracket(startingAt: openBracket, in: text)
        var metadataIndex = text.index(after: closeBracket)
        while metadataIndex < text.endIndex, text[metadataIndex].isWhitespace {
            metadataIndex = text.index(after: metadataIndex)
        }
        guard metadataIndex < text.endIndex, text[metadataIndex] == "(" else {
            return nil
        }
        let closeParenthesis = try matchingParenthesis(startingAt: metadataIndex, in: text)
        let metadataBody = String(text[text.index(after: metadataIndex)..<closeParenthesis])
        return try parseOptionalString(named: metadataName, in: metadataBody)
    }

    private func parsePointArray(named name: String, in text: String) throws -> [USDPoint3D] {
        try parsePointArray(named: name, in: text, options: .default)
    }

    private func parsePointArray(
        named name: String,
        in text: String,
        options: USDReadingOptions
    ) throws -> [USDPoint3D] {
        if let timeSamplesBody = try optionalTimeSamplesBody(named: name, in: text),
           let sampledPoints = try parsePointTimeSamples(named: name, in: timeSamplesBody, options: options) {
            return sampledPoints
        }
        let body = try bracketArrayBody(named: name, in: text)
        return try parsePointTuples(named: name, in: body)
    }

    private func parseOptionalPointArray(named name: String, in text: String) throws -> [USDPoint3D]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        return try parsePointTuples(named: name, in: body)
    }

    private func parseOptionalPoint2Array(named name: String, in text: String) throws -> [USDPoint2D]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        return try parsePoint2Tuples(named: name, in: body)
    }

    private func parseOptionalColorArray(named name: String, in text: String) throws -> [USDColorRGB]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        return try parseColorTuples(named: name, in: body)
    }

    private func parseOptionalDoubleArray(named name: String, in text: String) throws -> [Double]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        return try parseDoubleTokens(named: name, in: body)
    }

    private func parseRequiredScalar(named name: String, in text: String) throws -> Double {
        guard let nameRange = attributeNameRange(named: name, in: text) else {
            throw USDImportError.missingRequiredField(name)
        }
        guard let equalSign = text[nameRange.upperBound...].firstIndex(of: "=") else {
            throw USDImportError.invalidData("USDA \(name) is missing an assignment.")
        }
        var valueStart = text.index(after: equalSign)
        skipWhitespace(in: text, index: &valueStart)
        var valueEnd = valueStart
        while valueEnd < text.endIndex {
            let character = text[valueEnd]
            if character.isWhitespace
                || character == ","
                || character == ")"
                || character == "]"
                || character == "("
                || character == "{" {
                break
            }
            valueEnd = text.index(after: valueEnd)
        }
        guard valueStart < valueEnd,
              let value = Double(text[valueStart..<valueEnd]),
              value.isFinite else {
            throw USDImportError.invalidData("USDA \(name) contains a non-finite number.")
        }
        return value
    }

    private func parseRequiredVector3(named name: String, in text: String) throws -> USDTransformVector3D {
        let values = try parseRequiredTuple(named: name, expectedCount: 3, in: text)
        return USDTransformVector3D(x: values[0], y: values[1], z: values[2])
    }

    private func parseRequiredQuaternion(named name: String, in text: String) throws -> USDTransformQuaternion {
        let values = try parseRequiredTuple(named: name, expectedCount: 4, in: text)
        return USDTransformQuaternion(
            real: values[0],
            imaginaryX: values[1],
            imaginaryY: values[2],
            imaginaryZ: values[3]
        )
    }

    private func parseRequiredMatrix4x4(named name: String, in text: String) throws -> USDTransformMatrix4x4 {
        let values = try parseRequiredTuple(named: name, expectedCount: 16, in: text)
        return USDTransformMatrix4x4(values: values)
    }

    private func parseRequiredTuple(
        named name: String,
        expectedCount: Int,
        in text: String
    ) throws -> [Double] {
        guard let nameRange = attributeNameRange(named: name, in: text) else {
            throw USDImportError.missingRequiredField(name)
        }
        guard let equalSign = text[nameRange.upperBound...].firstIndex(of: "=") else {
            throw USDImportError.invalidData("USDA \(name) is missing an assignment.")
        }
        guard let openParenthesis = text[equalSign...].firstIndex(of: "(") else {
            throw USDImportError.invalidData("USDA \(name) is missing an opening parenthesis.")
        }
        let closeParenthesis = try matchingParenthesis(startingAt: openParenthesis, in: text)
        let body = String(text[text.index(after: openParenthesis)..<closeParenthesis])
        let values = try parseDoubleLiterals(named: name, in: body)
        guard values.count == expectedCount else {
            throw USDImportError.invalidData("USDA \(name) tuple contains \(values.count) values.")
        }
        return values
    }

    private func parsePointTuples(named name: String, in body: String) throws -> [USDPoint3D] {
        let expression = try NSRegularExpression(pattern: "\\(([^)]*)\\)")
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = expression.matches(in: body, range: range)
        guard !matches.isEmpty else {
            throw USDImportError.invalidData("USDA \(name) contains no point tuples.")
        }
        return try matches.map { match in
            let tuple = String(body[Range(match.range(at: 1), in: body)!])
            let parts = tuple.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 3,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  let z = Double(parts[2]),
                  x.isFinite,
                  y.isFinite,
                  z.isFinite else {
                throw USDImportError.invalidData("USDA point tuple is malformed.")
            }
            return USDPoint3D(x: x, y: y, z: z)
        }
    }

    private func parsePoint2Tuples(named name: String, in body: String) throws -> [USDPoint2D] {
        let expression = try NSRegularExpression(pattern: "\\(([^)]*)\\)")
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = expression.matches(in: body, range: range)
        guard !matches.isEmpty else {
            throw USDImportError.invalidData("USDA \(name) contains no point tuples.")
        }
        return try matches.map { match in
            let tuple = String(body[Range(match.range(at: 1), in: body)!])
            let parts = tuple.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  x.isFinite,
                  y.isFinite else {
                throw USDImportError.invalidData("USDA point2 tuple is malformed.")
            }
            return USDPoint2D(x: x, y: y)
        }
    }

    private func parsePointTimeSamples(
        named name: String,
        in body: String,
        options: USDReadingOptions
    ) throws -> [USDPoint3D]? {
        let entries = try parseTimeSampleEntries(in: body)
        guard !entries.isEmpty else {
            throw USDImportError.invalidData("USDA \(name).timeSamples contains no samples.")
        }
        var samples: [(timeCode: Double, points: [USDPoint3D])] = []
        for entry in entries {
            guard entry.value != "None" else {
                if let timeCode = options.timeCode, entry.timeCode == timeCode {
                    return nil
                }
                continue
            }
            let sample = try parsePointTuples(named: "\(name).timeSamples", in: entry.value)
            samples.append((timeCode: entry.timeCode, points: sample))
        }
        samples.sort { lhs, rhs in
            lhs.timeCode < rhs.timeCode
        }
        guard let timeCode = options.timeCode else {
            return samples.first?.points
        }
        return interpolatedPointSample(
            samples,
            at: timeCode,
            interpolation: options.timeSampleInterpolation
        )
    }

    private func interpolatedPointSample(
        _ samples: [(timeCode: Double, points: [USDPoint3D])],
        at timeCode: Double,
        interpolation: USDTimeSampleInterpolation
    ) -> [USDPoint3D]? {
        var lowerSample: (timeCode: Double, points: [USDPoint3D])?
        var upperSample: (timeCode: Double, points: [USDPoint3D])?
        for sample in samples {
            if sample.timeCode == timeCode {
                return sample.points
            }
            if sample.timeCode < timeCode {
                lowerSample = sample
            } else if sample.timeCode > timeCode {
                upperSample = sample
                break
            }
        }
        switch interpolation {
        case .held:
            return lowerSample?.points ?? upperSample?.points
        case .linear:
            guard let lowerSample else {
                return upperSample?.points
            }
            guard let upperSample else {
                return lowerSample.points
            }
            guard upperSample.timeCode > lowerSample.timeCode,
                  lowerSample.points.count == upperSample.points.count else {
                return lowerSample.points
            }
            let fraction = (timeCode - lowerSample.timeCode) / (upperSample.timeCode - lowerSample.timeCode)
            guard fraction.isFinite else {
                return lowerSample.points
            }
            return zip(lowerSample.points, upperSample.points).map { lower, upper in
                USDPoint3D(
                    x: lower.x + (upper.x - lower.x) * fraction,
                    y: lower.y + (upper.y - lower.y) * fraction,
                    z: lower.z + (upper.z - lower.z) * fraction
                )
            }
        }
    }

    private func parseTimeSampleEntries(in body: String) throws -> [(timeCode: Double, value: String)] {
        let expression = try NSRegularExpression(
            pattern: "([-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?)\\s*:\\s*(None|\\[[^\\]]*\\])"
        )
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return try expression.matches(in: body, range: range).map { match in
            guard let timeRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body),
                  let timeCode = Double(body[timeRange]),
                  timeCode.isFinite else {
                throw USDImportError.invalidData("USDA timeSamples entry is malformed.")
            }
            return (timeCode: timeCode, value: String(body[valueRange]))
        }
    }

    private func parseColorTuples(named name: String, in body: String) throws -> [USDColorRGB] {
        let expression = try NSRegularExpression(pattern: "\\(([^)]*)\\)")
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = expression.matches(in: body, range: range)
        guard !matches.isEmpty else {
            throw USDImportError.invalidData("USDA \(name) contains no color tuples.")
        }
        return try matches.map { match in
            let tuple = String(body[Range(match.range(at: 1), in: body)!])
            let parts = tuple.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 3,
                  let r = Double(parts[0]),
                  let g = Double(parts[1]),
                  let b = Double(parts[2]),
                  r.isFinite,
                  g.isFinite,
                  b.isFinite else {
                throw USDImportError.invalidData("USDA color tuple is malformed.")
            }
            return USDColorRGB(r: r, g: g, b: b)
        }
    }

    private func parseIntArray(named name: String, in text: String) throws -> [Int] {
        let body = try bracketArrayBody(named: name, in: text)
        return try parseIntTokens(named: name, in: body)
    }

    private func parseOptionalIntArray(named name: String, in text: String) throws -> [Int]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        return try parseIntTokens(named: name, in: body)
    }

    private func parseIntTokens(named name: String, in body: String) throws -> [Int] {
        let tokens = body.split { character in
            character == "," || character.isWhitespace || character.isNewline
        }
        guard !tokens.isEmpty else {
            throw USDImportError.invalidData("USDA \(name) is empty.")
        }
        return try tokens.map { token in
            guard let value = Int(token) else {
                throw USDImportError.invalidData("USDA \(name) contains a non-integer value.")
            }
            return value
        }
    }

    private func parseDoubleTokens(named name: String, in body: String) throws -> [Double] {
        let tokens = body.split { character in
            character == "," || character.isWhitespace || character.isNewline
        }
        guard !tokens.isEmpty else {
            throw USDImportError.invalidData("USDA \(name) is empty.")
        }
        return try tokens.map { token in
            guard let value = Double(token), value.isFinite else {
                throw USDImportError.invalidData("USDA \(name) contains a non-finite number.")
            }
            return value
        }
    }

    private func parseDoubleLiterals(named name: String, in body: String) throws -> [Double] {
        let pattern = "[-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?"
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = expression.matches(in: body, range: range)
        guard !matches.isEmpty else {
            throw USDImportError.invalidData("USDA \(name) is empty.")
        }
        return try matches.map { match in
            guard let valueRange = Range(match.range, in: body),
                  let value = Double(body[valueRange]),
                  value.isFinite else {
                throw USDImportError.invalidData("USDA \(name) contains a non-finite number.")
            }
            return value
        }
    }

    private func bracketArrayBody(named name: String, in text: String) throws -> String {
        guard let nameRange = attributeNameRange(named: name, in: text) else {
            throw USDImportError.missingRequiredField(name)
        }
        return try bracketArrayBody(after: nameRange.upperBound, named: name, in: text)
    }

    private func optionalBracketArrayBody(named name: String, in text: String) throws -> String? {
        guard let nameRange = attributeNameRange(named: name, in: text) else {
            return nil
        }
        return try bracketArrayBody(after: nameRange.upperBound, named: name, in: text)
    }

    private func optionalTimeSamplesBody(named name: String, in text: String) throws -> String? {
        guard let nameRange = attributeNameRange(named: "\(name).timeSamples", in: text) else {
            return nil
        }
        guard let openBrace = text[nameRange.upperBound...].firstIndex(of: "{") else {
            throw USDImportError.invalidData("USDA \(name).timeSamples is missing an opening brace.")
        }
        let closeBrace = try matchingBrace(startingAt: openBrace, in: text)
        return String(text[text.index(after: openBrace)..<closeBrace])
    }

    private func bracketArrayBody(after index: String.Index, named name: String, in text: String) throws -> String {
        guard let openBracket = text[index...].firstIndex(of: "[") else {
            throw USDImportError.invalidData("USDA \(name) is missing an opening bracket.")
        }
        let closeBracket = try matchingBracket(startingAt: openBracket, in: text)
        return String(text[text.index(after: openBracket)..<closeBracket])
    }

    private func attributeNameRange(named name: String, in text: String) -> Range<String.Index>? {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: name, range: searchRange) {
            let hasValidLeadingBoundary: Bool
            if range.lowerBound == text.startIndex {
                hasValidLeadingBoundary = true
            } else {
                let previous = text[text.index(before: range.lowerBound)]
                hasValidLeadingBoundary = previous.isWhitespace || previous == "]" || previous == "(" || previous == ","
            }

            let hasValidTrailingBoundary: Bool
            if range.upperBound == text.endIndex {
                hasValidTrailingBoundary = true
            } else {
                let next = text[range.upperBound]
                hasValidTrailingBoundary = next.isWhitespace
                    || next == "="
                    || next == "["
                    || next == "("
                    || next == ","
                    || next == ")"
            }

            if hasValidLeadingBoundary && hasValidTrailingBoundary {
                return range
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return nil
    }

    private func matchingBrace(startingAt openBrace: String.Index, in text: String) throws -> String.Index {
        try matchingDelimiter(startingAt: openBrace, open: "{", close: "}", in: text)
    }

    private func matchingBracket(startingAt openBracket: String.Index, in text: String) throws -> String.Index {
        try matchingDelimiter(startingAt: openBracket, open: "[", close: "]", in: text)
    }

    private func matchingParenthesis(startingAt openParenthesis: String.Index, in text: String) throws -> String.Index {
        try matchingDelimiter(startingAt: openParenthesis, open: "(", close: ")", in: text)
    }

    private func matchingDelimiter(
        startingAt openIndex: String.Index,
        open: Character,
        close: Character,
        in text: String
    ) throws -> String.Index {
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &index)
                continue
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = text.index(after: index)
        }
        throw USDImportError.invalidData("USDA delimiter is unterminated.")
    }

    private func skipQuotedString(in text: String, index: inout String.Index) throws {
        let quote = text[index]
        let delimiterLength = repeatedQuoteCount(at: index, quote: quote, in: text) >= 3 ? 3 : 1
        index = text.index(index, offsetBy: delimiterLength)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex {
                    index = text.index(after: index)
                }
                continue
            }
            if repeatedQuoteCount(at: index, quote: quote, in: text) >= delimiterLength {
                index = text.index(index, offsetBy: delimiterLength)
                return
            }
            index = text.index(after: index)
        }
        throw USDImportError.invalidData("USDA string is unterminated.")
    }

    private func repeatedQuoteCount(at index: String.Index, quote: Character, in text: String) -> Int {
        var cursor = index
        var count = 0
        while cursor < text.endIndex, text[cursor] == quote {
            count += 1
            cursor = text.index(after: cursor)
        }
        return count
    }

    private func firstMatch(pattern: String, in text: String) throws -> String? {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }
}

private struct USDAPrim {
    var specifier: USDPrimSpecifier
    var typeName: String?
    var name: String?
    var metadataBody: String
    var body: String
    var fullRange: Range<String.Index>
}

private struct USDALocalTransform {
    var matrix: USDTransformMatrix4x4
    var resetsParentStack: Bool
}
