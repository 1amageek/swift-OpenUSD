import Foundation

public struct USDAReader: USDSceneReader {
    public init() {}

    public func read(from data: Data) throws -> USDScene {
        try read(from: data, options: .default)
    }

    public func read(from data: Data, options: USDReadingOptions) throws -> USDScene {
        guard let text = String(data: data, encoding: .utf8) else {
            throw USDError.invalidData("USDA data is not UTF-8.")
        }
        return try read(from: text, options: options)
    }

    public func readLayer(from data: Data) throws -> USDALayer {
        guard let text = String(data: data, encoding: .utf8) else {
            throw USDError.invalidData("USDA data is not UTF-8.")
        }
        return try readLayer(from: text)
    }

    public func read(from text: String) throws -> USDScene {
        try read(from: text, options: .default)
    }

    public func read(from text: String, options: USDReadingOptions) throws -> USDScene {
        let text = try readerVisibleText(from: text)
        try validateSignature(in: text)
        // Parse the top-level prim list once and share it between validation
        // and every downstream consumer.
        let rootPrims = try validateTopLevelSyntax(in: text)
        let metadataBody = try layerMetadataBody(in: text)
        try validateLayerMetadataStatements(in: metadataBody)
        try validateRelocatesMetadata(in: metadataBody)
        try validatePrimAttributeSyntax(prims: rootPrims)
        try validateUniqueSiblingPrimPaths(prims: rootPrims, parentPrimPath: "")
        if let timeCode = options.timeCode, !timeCode.isFinite {
            throw USDError.invalidData("USDA requested timeCode must be finite.")
        }
        // Upstream USD falls back to 0.01 (centimeters) when layer metadata
        // does not author metersPerUnit (UsdGeomLinearUnits / UsdGeomGetStageMetersPerUnit).
        let metersPerUnit = try metadataBody.flatMap {
            try parseOptionalDouble(named: "metersPerUnit", in: $0)
        } ?? 0.01
        guard metersPerUnit.isFinite, metersPerUnit > 0 else {
            throw USDError.invalidData("USDA metersPerUnit must be a positive finite value.")
        }
        let upAxis = try metadataBody.map { try parseUpAxis(in: $0) } ?? .y
        let defaultPrim = try metadataBody.flatMap { try parseOptionalString(named: "defaultPrim", in: $0) }
        let meshes = try parseMeshes(prims: rootPrims, options: options)
        guard !meshes.isEmpty else {
            throw USDError.invalidData("USDA scene contains no Mesh prims.")
        }
        return USDScene(defaultPrim: defaultPrim, metersPerUnit: metersPerUnit, upAxis: upAxis, meshes: meshes)
    }

    public func readLayer(from text: String) throws -> USDALayer {
        let text = try readerVisibleText(from: text)
        try validateSignature(in: text)
        // Parse the top-level prim list once and share it between validation
        // and every downstream consumer.
        let rootPrims = try validateTopLevelSyntax(in: text)
        let metadataBody = try layerMetadataBody(in: text)
        try validateLayerMetadataStatements(in: metadataBody)
        try validateRelocatesMetadata(in: metadataBody)
        try validatePrimAttributeSyntax(prims: rootPrims)
        let specs = try parseLayerSpecs(prims: rootPrims, metadataBody: metadataBody)
        try validateUniqueSiblingPrimPaths(prims: rootPrims, parentPrimPath: "")
        let defaultPrim = try metadataBody.flatMap { try parseOptionalString(named: "defaultPrim", in: $0) }
        let metersPerUnit = try metadataBody.flatMap { try parseOptionalDouble(named: "metersPerUnit", in: $0) }
        if let metersPerUnit, (!metersPerUnit.isFinite || metersPerUnit <= 0) {
            throw USDError.invalidData("USDA metersPerUnit must be a positive finite value.")
        }
        let upAxisToken = try metadataBody.flatMap { try parseOptionalString(named: "upAxis", in: $0) }
        let upAxis: USDUpAxis?
        if let upAxisToken {
            guard let parsed = USDUpAxis(rawValue: upAxisToken) else {
                throw USDError.invalidData("Unsupported USDA upAxis \(upAxisToken).")
            }
            upAxis = parsed
        } else {
            upAxis = nil
        }
        return USDALayer(
            defaultPrim: defaultPrim,
            metersPerUnit: metersPerUnit,
            upAxis: upAxis,
            composition: try parseLayerComposition(prims: rootPrims, metadataBody: metadataBody),
            specs: specs,
            primTransforms: try parsePrimTransforms(prims: rootPrims),
            resetXformStackPrimPaths: try parseResetXformStackPrimPaths(prims: rootPrims)
        )
    }

    public func readComposition(from data: Data) throws -> USDLayerComposition {
        try readLayer(from: data).composition
    }

    private func validateSignature(in text: String) throws {
        // Skip only the leading whitespace/newlines instead of trimming (and
        // copying) the entire document just to check a five-character prefix.
        let scalars = text.unicodeScalars
        let whitespaceAndNewlines = CharacterSet.whitespacesAndNewlines
        var index = scalars.startIndex
        while index < scalars.endIndex, whitespaceAndNewlines.contains(scalars[index]) {
            index = scalars.index(after: index)
        }
        guard scalars[index...].starts(with: "#usda".unicodeScalars) else {
            throw USDError.invalidData("USDA data is missing the #usda signature.")
        }
    }

    /// Validates the top-level structure and returns the parsed direct prims.
    /// The parse performed here is shared with downstream validation and
    /// consumers so the top-level prim list is built exactly once per document.
    private func validateTopLevelSyntax(in text: String) throws -> [USDAPrim] {
        var prims: [USDAPrim] = []
        var cursor = topLevelSyntaxStart(in: text)
        var hasReadMetadata = false
        while true {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex else {
                return prims
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
                prims.append(prim)
                cursor = prim.fullRange.upperBound
                continue
            }
            throw USDError.invalidData("USDA contains unexpected top-level syntax.")
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

    private func validatePrimAttributeSyntax(prims: [USDAPrim]) throws {
        for prim in prims {
            let directAttributeText = try directAttributeText(from: prim.body)
            try validateBoolMetadata(named: "hidden", in: prim.metadataBody)
            try validateBoolMetadata(named: "hidden", in: directAttributeText)
            try validateBoolMetadata(named: "noLoadHint", in: directAttributeText)
            try validateStringMetadata(named: "kind", in: prim.metadataBody)
            try validateTokenMetadata(named: "access", allowedValues: ["private", "public"], in: prim.metadataBody)
            try validateTokenMetadata(named: "access", allowedValues: ["private", "public"], in: directAttributeText)
            try validateTokenMetadata(named: "permission", allowedValues: ["private", "public"], in: prim.metadataBody)
            try validateTokenMetadata(named: "permission", allowedValues: ["private", "public"], in: directAttributeText)
            try validateCompositionListEdits(in: prim.metadataBody)
            try validateRelocatesMetadata(in: prim.metadataBody)
            try validatePropertyDeclarations(in: directAttributeText)
            try validateScalarAssignments(in: directAttributeText)
            try validatePrimAttributeSyntax(prims: try parseDirectPrims(in: prim.body))
        }
    }

    private func validatePropertyDeclarations(in text: String) throws {
        let scalars = text.unicodeScalars
        var cursor = text.startIndex
        var isStatementStart = true
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while cursor < text.endIndex {
            let character = scalars[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                if parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0 {
                    isStatementStart = true
                }
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            }

            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel && (character == "\n" || character == "\r" || character == ";") {
                isStatementStart = true
                cursor = scalars.index(after: cursor)
                continue
            }
            if isAtTopLevel, isStatementStart {
                if isWhitespaceScalar(character) {
                    cursor = scalars.index(after: cursor)
                    continue
                }
                try validatePropertyDeclaration(startingAt: cursor, in: text)
                isStatementStart = false
            }
            cursor = scalars.index(after: cursor)
        }
    }

    private func validatePropertyDeclaration(startingAt index: String.Index, in text: String) throws {
        var cursor = index
        var qualifiers: [String] = []
        while let qualifier = propertyDeclarationQualifier(at: cursor, in: text) {
            qualifiers.append(qualifier)
            cursor = text.index(cursor, offsetBy: qualifier.count)
            try skipPropertyDeclarationWhitespace(in: text, index: &cursor)
        }
        if try validatePropertyOrderListEdit(qualifiers: qualifiers, startingAt: cursor, in: text) {
            return
        }
        guard cursor < text.endIndex else {
            return
        }
        let tokenStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "=" || character == "(" || character == "{" || character == ";" {
                break
            }
            cursor = text.index(after: cursor)
        }
        guard tokenStart < cursor else {
            return
        }
        let authoredTypeName = String(text[tokenStart..<cursor])
        let isArrayType = authoredTypeName.contains("[]")
        let baseTypeName: String
        if let arraySuffix = authoredTypeName.firstIndex(of: "[") {
            baseTypeName = String(authoredTypeName[..<arraySuffix])
        } else {
            baseTypeName = authoredTypeName
        }
        guard isValidUSDPropertyTypeName(baseTypeName) else {
            throw USDError.invalidData("USDA property type name \(baseTypeName) is not a valid identifier.")
        }
        var valueCursor = cursor
        try skipPropertyDeclarationWhitespace(in: text, index: &valueCursor)
        try validatePropertyValueShape(
            qualifiers: qualifiers,
            typeName: authoredTypeName,
            isArrayType: isArrayType,
            afterTypeName: valueCursor,
            in: text
        )
    }

    private func validatePropertyValueShape(
        qualifiers: [String],
        typeName: String,
        isArrayType: Bool,
        afterTypeName cursor: String.Index,
        in text: String
    ) throws {
        var cursor = cursor
        skipWhitespace(in: text, index: &cursor)
        let propertyNameStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "=" || character == "(" || character == ";" || character == "{" {
                break
            }
            cursor = text.index(after: cursor)
        }
        let propertyName = String(text[propertyNameStart..<cursor])
        guard !propertyName.isEmpty else {
            throw USDError.invalidData("USDA property declaration is missing a property name.")
        }
        let normalizedPropertyName = normalizedPropertyName(propertyName)
        guard isValidUSDPropertyName(normalizedPropertyName.baseName) else {
            throw USDError.invalidData("USDA property name \(propertyName) is not a valid identifier.")
        }
        if skipPropertyNameTrailingWhitespace(in: text, index: &cursor) {
            return
        }
        if cursor < text.endIndex, text[cursor] == "(" {
            let closeParenthesis = try matchingParenthesis(startingAt: cursor, in: text)
            cursor = text.index(after: closeParenthesis)
            if skipPropertyNameTrailingWhitespace(in: text, index: &cursor) {
                return
            }
        }
        guard cursor < text.endIndex, text[cursor] == "=" else {
            throw USDError.invalidData("USDA property declaration contains unexpected token after property name.")
        }
        cursor = text.index(after: cursor)
        try skipPropertyValueStartWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex else {
            return
        }
        if typeName == "opaque", !propertyName.hasSuffix(".connect") {
            throw USDError.invalidData("USDA opaque attribute \(propertyName) cannot author a default value.")
        }
        if isNoneValue(at: cursor, in: text) {
            if qualifiers.contains(where: isListEditQualifier) {
                throw USDError.invalidData("USDA \(propertyName) list-edit cannot use None.")
            }
            return
        }
        if propertyName.hasSuffix(".connect") {
            try validateRelationshipTargetValue(named: propertyName, startingAt: cursor, in: text)
            try validateTargetListEditValue(qualifiers: qualifiers, propertyName: propertyName, startingAt: cursor, in: text)
            return
        }
        if typeName == "rel" {
            try validateRelationshipTargetValue(named: propertyName, startingAt: cursor, in: text)
            try validateTargetListEditValue(qualifiers: qualifiers, propertyName: propertyName, startingAt: cursor, in: text)
            return
        }
        if isArrayType {
            guard text[cursor] == "[" || (propertyName.hasSuffix(".timeSamples") && text[cursor] == "{") else {
                throw USDError.invalidData("USDA \(typeName) attribute must use a shaped list value.")
            }
            if text[cursor] == "[" {
                try validateArrayAttributeValue(
                    typeName: typeName,
                    propertyName: propertyName,
                    startingAt: cursor,
                    in: text
                )
            }
        } else if text[cursor] == "[", Self.knownScalarValueTypes.contains(typeName) {
            throw USDError.invalidData("USDA \(typeName) attribute cannot use a shaped list value.")
        }
    }

    private static let knownScalarValueTypes: Set<String> = [
        "asset",
        "bool",
        "color3d",
        "color3f",
        "color3h",
        "color4d",
        "color4f",
        "color4h",
        "double",
        "double2",
        "double3",
        "double4",
        "float",
        "float2",
        "float3",
        "float4",
        "frame4d",
        "half",
        "half2",
        "half3",
        "half4",
        "int",
        "int64",
        "int2",
        "int3",
        "int4",
        "matrix2d",
        "matrix3d",
        "matrix4d",
        "normal3d",
        "normal3f",
        "normal3h",
        "point3d",
        "point3f",
        "point3h",
        "quatd",
        "quatf",
        "quath",
        "string",
        "texCoord2d",
        "texCoord2f",
        "texCoord2h",
        "texCoord3d",
        "texCoord3f",
        "texCoord3h",
        "timecode",
        "token",
        "uchar",
        "uint",
        "uint64",
        "vector3d",
        "vector3f",
        "vector3h",
    ]

    private func validateTargetListEditValue(
        qualifiers: [String],
        propertyName: String,
        startingAt cursor: String.Index,
        in text: String
    ) throws {
        guard qualifiers.contains("add"), cursor < text.endIndex, text[cursor] == "[" else {
            return
        }
        let targetCount = try countAngleTargetPaths(inBracketListStartingAt: cursor, in: text)
        guard targetCount > 0 else {
            throw USDError.invalidData("USDA \(propertyName) add list-edit cannot use an empty target list.")
        }
    }

    private func countAngleTargetPaths(inBracketListStartingAt openBracket: String.Index, in text: String) throws -> Int {
        let closeBracket = try matchingBracket(startingAt: openBracket, in: text)
        var cursor = text.index(after: openBracket)
        var count = 0
        while cursor < closeBracket {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if character == "<" {
                count += 1
            }
            cursor = text.index(after: cursor)
        }
        return count
    }

    private func validatePropertyOrderListEdit(
        qualifiers: [String],
        startingAt cursor: String.Index,
        in text: String
    ) throws -> Bool {
        guard qualifiers.contains(where: isListEditQualifier),
              token("properties", matchesAt: cursor, in: text) else {
            return false
        }
        var valueCursor = text.index(cursor, offsetBy: "properties".count)
        try skipPropertyDeclarationWhitespace(in: text, index: &valueCursor)
        guard valueCursor < text.endIndex, text[valueCursor] == "=" else {
            throw USDError.invalidData("USDA properties list-edit is missing an assignment.")
        }
        valueCursor = text.index(after: valueCursor)
        try skipPropertyValueStartWhitespace(in: text, index: &valueCursor)
        guard valueCursor < text.endIndex, text[valueCursor] == "[" else {
            throw USDError.invalidData("USDA properties list-edit must use a bracketed list value.")
        }
        _ = try matchingBracket(startingAt: valueCursor, in: text)
        return true
    }

    private func validateArrayAttributeValue(
        typeName: String,
        propertyName: String,
        startingAt openBracket: String.Index,
        in text: String
    ) throws {
        let closeBracket = try matchingBracket(startingAt: openBracket, in: text)
        var cursor = text.index(after: openBracket)
        while cursor < closeBracket {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if character == "[" {
                throw USDError.invalidData(
                    "USDA \(typeName) attribute \(propertyName) contains a nested shaped list value."
                )
            }
            cursor = text.index(after: cursor)
        }
    }

    private func validateRelationshipTargetValue(
        named propertyName: String,
        startingAt cursor: String.Index,
        in text: String
    ) throws {
        guard cursor < text.endIndex else {
            return
        }
        if text[cursor] == "<" {
            let parsedTarget = try parseRelationshipTargetPath(
                named: propertyName,
                startingAt: cursor,
                before: text.endIndex,
                in: text
            )
            try validateRelationshipTrailingContent(
                named: propertyName,
                startingAt: parsedTarget.endIndex,
                in: text
            )
            return
        }
        guard text[cursor] == "[" else {
            throw USDError.invalidData("USDA relationship \(propertyName) target contains invalid target syntax.")
        }
        let closeBracket = try matchingBracket(startingAt: cursor, in: text)
        var listCursor = text.index(after: cursor)
        var targets: Set<String> = []
        while listCursor < closeBracket {
            skipWhitespaceAndLineComments(in: text, index: &listCursor)
            guard listCursor < closeBracket else {
                break
            }
            if text[listCursor] == "," {
                listCursor = text.index(after: listCursor)
                continue
            }
            guard text[listCursor] == "<" else {
                throw USDError.invalidData("USDA relationship \(propertyName) target list contains invalid target syntax.")
            }
            let parsedTarget = try parseRelationshipTargetPath(
                named: propertyName,
                startingAt: listCursor,
                before: closeBracket,
                in: text
            )
            listCursor = parsedTarget.endIndex
            let target = parsedTarget.value
            guard targets.insert(target).inserted else {
                throw USDError.invalidData("USDA relationship \(propertyName) contains duplicate target \(target).")
            }
        }
        try validateRelationshipTrailingContent(
            named: propertyName,
            startingAt: text.index(after: closeBracket),
            in: text
        )
    }

    private func parseRelationshipTargetPath(
        named propertyName: String,
        startingAt start: String.Index,
        before end: String.Index,
        in text: String
    ) throws -> (value: String, endIndex: String.Index) {
        var cursor = start
        guard cursor < end, text[cursor] == "<" else {
            throw USDError.invalidData("USDA relationship \(propertyName) target contains invalid target syntax.")
        }
        while cursor < end, text[cursor] != ">" {
            cursor = text.index(after: cursor)
        }
        guard cursor < end else {
            throw USDError.invalidData("USDA relationship \(propertyName) target contains unterminated target path.")
        }
        let value = String(text[text.index(after: start)..<cursor])
        try validateUSDPath(value, subject: "relationship \(propertyName) target")
        return (String(text[start...cursor]), text.index(after: cursor))
    }

    private func validateRelationshipTrailingContent(
        named propertyName: String,
        startingAt start: String.Index,
        in text: String
    ) throws {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                if text[cursor].isNewline {
                    return
                }
                cursor = text.index(after: cursor)
                continue
            }
            if text[cursor] == "#" {
                return
            }
            if text[cursor] == ";" || text[cursor] == "}" {
                return
            }
            if text[cursor] == "(" {
                let closeParenthesis = try matchingParenthesis(startingAt: cursor, in: text)
                cursor = text.index(after: closeParenthesis)
                continue
            }
            throw USDError.invalidData("USDA relationship \(propertyName) target contains unexpected trailing content.")
        }
    }

    private func propertyDeclarationQualifier(at index: String.Index, in text: String) -> String? {
        for qualifier in ["custom", "uniform", "varying", "delete", "add", "prepend", "append", "reorder"] {
            guard token(qualifier, matchesAt: index, in: text) else {
                continue
            }
            return qualifier
        }
        return nil
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
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
            guard value == "true" || value == "false" || value == "True" || value == "False" else {
                throw USDError.invalidData("USDA \(name) metadata contains invalid bool value \(value).")
            }
            cursor = valueCursor
        }
    }

    private func validateStringMetadata(named name: String, in text: String) throws {
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
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
            if valueCursor < text.endIndex, text[valueCursor] == "\"" || text[valueCursor] == "'" {
                try skipQuotedString(in: text, index: &valueCursor)
                cursor = valueCursor
                continue
            }
            let valueStart = valueCursor
            while valueCursor < text.endIndex {
                let character = text[valueCursor]
                if character.isWhitespace || character == ";" || character == "," || character == ")" {
                    break
                }
                valueCursor = text.index(after: valueCursor)
            }
            let value = String(text[valueStart..<valueCursor])
            guard value == "None" else {
                throw USDError.invalidData("USDA \(name) metadata contains invalid string value \(value).")
            }
            cursor = valueCursor
        }
    }

    private func validateTokenMetadata(
        named name: String,
        allowedValues: Set<String>,
        in text: String
    ) throws {
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
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
            guard allowedValues.contains(value) else {
                throw USDError.invalidData("USDA \(name) metadata contains invalid value \(value).")
            }
            cursor = valueCursor
        }
    }

    private func validateCompositionListEdits(in text: String) throws {
        try validateBracketedListEdits(forField: "references", in: text)
        try validateBracketedListEdits(forField: "payload", in: text)
    }

    private func validateRelocatesMetadata(in metadataBody: String?) throws {
        guard let metadataBody else {
            return
        }
        try validateRelocatesMetadata(in: metadataBody)
    }

    private func validateRelocatesMetadata(in text: String) throws {
        var cursor = text.startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }

            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel, token("relocates", matchesAt: cursor, in: text) {
                cursor = try validateRelocatesAssignment(startingAt: cursor, in: text)
                continue
            }

            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            }
            cursor = text.index(after: cursor)
        }
    }

    private func validateRelocatesAssignment(startingAt index: String.Index, in text: String) throws -> String.Index {
        var cursor = text.index(index, offsetBy: "relocates".count)
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "=" else {
            return cursor
        }
        cursor = text.index(after: cursor)
        skipWhitespaceAndLineComments(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "{" else {
            throw USDError.invalidData("USDA relocates metadata must use a map value.")
        }
        let closeBrace = try matchingBrace(startingAt: cursor, in: text)
        try validateRelocatesMapEntries(from: text.index(after: cursor), to: closeBrace, in: text)
        return text.index(after: closeBrace)
    }

    private func validateRelocatesMapEntries(
        from start: String.Index,
        to end: String.Index,
        in text: String
    ) throws {
        var cursor = start
        while cursor < end {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < end else {
                return
            }
            let sourcePath = try parseRelocatesPath(role: "source", at: &cursor, before: end, in: text)
            try validateRelocatesPath(sourcePath, role: "source")
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < end, text[cursor] == ":" else {
                throw USDError.invalidData("USDA relocates metadata must separate source and target paths with ':'.")
            }
            cursor = text.index(after: cursor)
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            let targetPath = try parseRelocatesPath(role: "target", at: &cursor, before: end, in: text)
            try validateRelocatesPath(targetPath, role: "target")
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            if cursor < end {
                guard text[cursor] == "," else {
                    throw USDError.invalidData("USDA relocates metadata entries must be separated by commas.")
                }
                cursor = text.index(after: cursor)
            }
        }
    }

    private func parseRelocatesPath(
        role: String,
        at cursor: inout String.Index,
        before end: String.Index,
        in text: String
    ) throws -> String {
        guard cursor < end, text[cursor] == "<" else {
            throw USDError.invalidData("USDA relocates \(role) path must use angle brackets.")
        }
        let pathStart = text.index(after: cursor)
        cursor = pathStart
        while cursor < end, text[cursor] != ">" {
            cursor = text.index(after: cursor)
        }
        guard cursor < end else {
            throw USDError.invalidData("USDA relocates \(role) path is unterminated.")
        }
        let path = String(text[pathStart..<cursor])
        cursor = text.index(after: cursor)
        return path
    }

    private func validateRelocatesPath(_ path: String, role: String) throws {
        if path.isEmpty {
            guard role == "target" else {
                throw USDError.invalidData("USDA relocates source path cannot be empty.")
            }
            return
        }
        guard path != "/" else {
            throw USDError.invalidData("USDA relocates \(role) path cannot be the pseudo-root path.")
        }
        guard !path.contains("{"), !path.contains("}") else {
            throw USDError.invalidData("USDA relocates \(role) path cannot contain variant selections.")
        }
        let invalidCharacters: Set<Character> = ["\\", "?", "*", "\"", "'"]
        guard !path.contains(where: { invalidCharacters.contains($0) || $0.isWhitespace }) else {
            throw USDError.invalidData("USDA relocates \(role) path contains invalid path characters.")
        }
    }

    private func validateBracketedListEdits(forField fieldName: String, in text: String) throws {
        var cursor = text.startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            guard isAtTopLevel else {
                if character == "(" {
                    parenthesisDepth += 1
                } else if character == ")" {
                    parenthesisDepth = max(0, parenthesisDepth - 1)
                } else if character == "[" {
                    bracketDepth += 1
                } else if character == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                } else if character == "{" {
                    braceDepth += 1
                } else if character == "}" {
                    braceDepth = max(0, braceDepth - 1)
                }
                cursor = text.index(after: cursor)
                continue
            }
            guard let qualifier = compositionListEditQualifier(at: cursor, in: text) else {
                if character == "(" {
                    parenthesisDepth += 1
                } else if character == "[" {
                    bracketDepth += 1
                } else if character == "{" {
                    braceDepth += 1
                }
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
                throw USDError.invalidData("USDA \(fieldName) \(qualifier) list-edit must use a bracketed list value.")
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
        prims: [USDAPrim],
        parentPrimPath: String
    ) throws {
        var seenPaths: Set<String> = []
        for prim in prims {
            let path = primPath(for: prim, parentPrimPath: parentPrimPath)
            guard seenPaths.insert(path).inserted else {
                throw USDError.invalidData("USDA contains duplicate prim path \(path).")
            }
            try validateUniqueSiblingPrimPaths(
                prims: parseDirectPrims(in: prim.body),
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
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
        let propertyNameStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "=" || character == "(" || character == "\n" || character == "\r" {
                break
            }
            cursor = text.index(after: cursor)
        }
        let propertyName = String(text[propertyNameStart..<cursor])
        let normalizedName = normalizedPropertyName(propertyName)
        if normalizedName.valueField == USDAPropertyValueField.connectionPaths
            || normalizedName.valueField == USDAPropertyValueField.timeSamples {
            return
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
        if valueType == "string", cursor < text.endIndex, text[cursor] == "\"" || text[cursor] == "'" {
            try skipQuotedString(in: text, index: &cursor)
        } else {
            while cursor < text.endIndex {
                let character = text[cursor]
                if character.isWhitespace || character == ";" || character == "," || character == ")" || character == "]" || character == "}" {
                    break
                }
                cursor = text.index(after: cursor)
            }
        }
        let value = String(text[valueStart..<cursor])
        switch valueType {
        case "bool":
            guard ["true", "false", "0", "1", "None"].contains(value) else {
                throw USDError.invalidData("USDA bool attribute contains invalid value \(value).")
            }
        case "double", "float", "half", "timecode":
            guard value == "None" || Double(value)?.isFinite == true else {
                throw USDError.invalidData("USDA \(valueType) attribute contains invalid value \(value).")
            }
        case "int":
            guard value == "None" || Int(value) != nil else {
                throw USDError.invalidData("USDA int attribute contains invalid value \(value).")
            }
        case "int64":
            guard value == "None" || Int64(value) != nil else {
                throw USDError.invalidData("USDA int64 attribute contains invalid value \(value).")
            }
        case "string":
            guard value == "None" || value.first == "\"" || value.first == "'" else {
                throw USDError.invalidData("USDA string attribute contains invalid value \(value).")
            }
        case "uchar":
            guard value == "None" || UInt8(value) != nil else {
                throw USDError.invalidData("USDA uchar attribute contains invalid value \(value).")
            }
        case "uint":
            guard value == "None" || UInt32(value) != nil else {
                throw USDError.invalidData("USDA uint attribute contains invalid value \(value).")
            }
        case "uint64":
            guard value == "None" || UInt64(value) != nil else {
                throw USDError.invalidData("USDA uint64 attribute contains invalid value \(value).")
            }
        default:
            return
        }
        try validateScalarTrailingContent(type: valueType, startingAt: cursor, in: text)
    }

    private func validateScalarTrailingContent(
        type valueType: String,
        startingAt start: String.Index,
        in text: String
    ) throws {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                if text[cursor].isNewline {
                    return
                }
                cursor = text.index(after: cursor)
                continue
            }
            if text[cursor] == "#" || text[cursor] == ";" || text[cursor] == "}" {
                return
            }
            if text[cursor] == "(" {
                let closeParenthesis = try matchingParenthesis(startingAt: cursor, in: text)
                cursor = text.index(after: closeParenthesis)
                continue
            }
            throw USDError.invalidData("USDA \(valueType) attribute contains unexpected trailing content.")
        }
    }

    private func scalarAttributeType(at index: String.Index, in text: String) -> String? {
        for keyword in ["timecode", "double", "float", "int64", "string", "uchar", "uint64", "bool", "half", "uint", "int"] {
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &index)
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
        character.unicodeScalars.allSatisfy { scalar in
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

    private func validateLayerMetadataStatements(in metadataBody: String?) throws {
        guard let text = metadataBody else {
            return
        }
        var cursor = text.startIndex
        var lineContainsAssignment = false
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if character.isNewline {
                lineContainsAssignment = false
                cursor = text.index(after: cursor)
                continue
            }
            if character == ";" {
                lineContainsAssignment = false
                cursor = text.index(after: cursor)
                continue
            }
            if isOpenLayerMetadataDelimiter(character) {
                try skipLayerMetadataDelimitedValue(in: text, index: &cursor)
                continue
            }
            if character == "=" {
                guard !lineContainsAssignment else {
                    throw USDError.invalidData(
                        "USDA layer metadata contains multiple statements on one line without a semicolon."
                    )
                }
                lineContainsAssignment = true
                try validateLayerMetadataValueStartsOnSameLine(afterEqualsAt: cursor, in: text)
            }
            cursor = text.index(after: cursor)
        }
    }

    private func validateLayerMetadataValueStartsOnSameLine(afterEqualsAt equalsIndex: String.Index, in text: String) throws {
        var cursor = text.index(after: equalsIndex)
        while cursor < text.endIndex, text[cursor].isWhitespace {
            if text[cursor].isNewline {
                throw USDError.invalidData("USDA layer metadata value cannot start on a new line after '='.")
            }
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] != "#" && text[cursor] != ";" else {
            throw USDError.invalidData("USDA layer metadata value is missing.")
        }
    }

    private func skipLayerMetadataDelimitedValue(in text: String, index: inout String.Index) throws {
        var expectedClosers: [Character] = []
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &index)
                continue
            }
            if let close = layerMetadataCloseDelimiter(for: character) {
                expectedClosers.append(close)
                index = text.index(after: index)
                continue
            }
            if let close = expectedClosers.last, character == close {
                expectedClosers.removeLast()
                index = text.index(after: index)
                if expectedClosers.isEmpty {
                    return
                }
                continue
            }
            index = text.index(after: index)
        }
        throw USDError.invalidData("USDA layer metadata value delimiter is unterminated.")
    }

    private func isOpenLayerMetadataDelimiter(_ character: Character) -> Bool {
        layerMetadataCloseDelimiter(for: character) != nil
    }

    private func layerMetadataCloseDelimiter(for character: Character) -> Character? {
        switch character {
        case "[":
            return "]"
        case "{":
            return "}"
        case "(":
            return ")"
        default:
            return nil
        }
    }

    private func parseLayerComposition(prims: [USDAPrim], metadataBody: String?) throws -> USDLayerComposition {
        var composition = USDLayerComposition()
        if let metadataBody {
            composition.sublayers = try parseSublayers(forField: "subLayers", in: metadataBody)
        }
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

    private func parseMeshes(prims: [USDAPrim], options: USDReadingOptions) throws -> [USDMesh] {
        try parseMeshes(prims: prims, options: options, inheritedTransform: .identity, parentPrimPath: "")
    }

    private func parseLayerSpecs(prims: [USDAPrim], metadataBody: String?) throws -> [USDLayerSpec] {
        let rootMetadata = try parseMetadataFields(in: metadataBody ?? "")
        var specs = [
            USDLayerSpec(
                path: "/",
                specType: .pseudoRoot,
                fieldNames: rootMetadata.fieldNames,
                fields: rootMetadata.fields
            )
        ]
        specs.append(contentsOf: try parseLayerSpecs(
            from: prims,
            parentPrimPath: ""
        ))
        return specs
    }

    private func parseLayerSpecs(from prims: [USDAPrim], parentPrimPath: String) throws -> [USDLayerSpec] {
        var specs: [USDLayerSpec] = []
        for prim in prims {
            let path = primPath(for: prim, parentPrimPath: parentPrimPath)
            let directBody = try directAttributeText(from: prim.body)
            let propertySpecs = try parsePropertySpecs(in: directBody, parentPrimPath: path)
            let variantSpecs = try parseVariantSetSpecs(in: prim.body, parentPrimPath: path)
            let metadata = try parseMetadataFields(in: prim.metadataBody)
            let propertyOrderOperation = try parsePropertyOrderListOperation(in: directBody, parentPrimPath: path)
            let metadataVariantSetSpecs = variantSetSpecsMaterializedFromMetadata(
                metadata.fields["variantSetNames"],
                parentPrimPath: path,
                existingSpecs: variantSpecs
            )
            var fields = metadata.fields
            fields["specifier"] = .authored(specifierKeyword(prim.specifier))
            var fieldNames = ["specifier"]
            if prim.typeName != nil {
                fieldNames.append("typeName")
                fields["typeName"] = prim.typeName.map { .authored($0) }
            }
            if let propertyOrderOperation {
                fieldNames.append("properties")
                fields["properties"] = .pathListOperation(propertyOrderOperation)
            } else if !propertySpecs.isEmpty {
                fieldNames.append("properties")
                fields["properties"] = .authored(propertySpecs.map(\.path).joined(separator: ", "))
            }
            fieldNames.append(contentsOf: metadata.fieldNames.filter { !fieldNames.contains($0) })
            specs.append(USDLayerSpec(
                path: path,
                specType: .prim,
                specifier: prim.specifier,
                typeName: prim.typeName,
                fieldNames: fieldNames,
                fields: fields
            ))
            specs.append(contentsOf: propertySpecs)
            specs.append(contentsOf: metadataVariantSetSpecs)
            specs.append(contentsOf: variantSpecs)
            specs.append(contentsOf: try parseLayerSpecs(
                from: parseDirectPrims(in: prim.body),
                parentPrimPath: path
            ))
        }
        return specs
    }

    private func parsePropertySpecs(in text: String, parentPrimPath: String) throws -> [USDLayerSpec] {
        var specs: [USDLayerSpec] = []
        var specIndexByPath: [String: Int] = [:]
        var cursor = text.startIndex
        var isStatementStart = true
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                isStatementStart = true
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            }

            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel && (character == "\n" || character == "\r" || character == ";") {
                isStatementStart = true
                cursor = text.index(after: cursor)
                continue
            }
            if isAtTopLevel, isStatementStart {
                if character.isWhitespace {
                    cursor = text.index(after: cursor)
                    continue
                }
                if let declaration = try parsePropertySpecDeclaration(
                    startingAt: cursor,
                    parentPrimPath: parentPrimPath,
                    in: text
                ) {
                    mergePropertySpec(declaration, into: &specs, specIndexByPath: &specIndexByPath)
                    for childSpec in declaration.childSpecs {
                        mergeLayerSpec(childSpec, into: &specs, specIndexByPath: &specIndexByPath)
                    }
                }
                isStatementStart = false
            }
            cursor = text.index(after: cursor)
        }
        return specs
    }

    private func parsePropertySpecDeclaration(
        startingAt index: String.Index,
        parentPrimPath: String,
        in text: String
    ) throws -> USDAPropertySpecDeclaration? {
        var cursor = index
        var qualifiers: [String] = []
        while let qualifier = propertyDeclarationQualifier(at: cursor, in: text) {
            qualifiers.append(qualifier)
            cursor = text.index(cursor, offsetBy: qualifier.count)
            try skipPropertyDeclarationWhitespace(in: text, index: &cursor)
        }
        if isPropertyOrderListEdit(qualifiers: qualifiers, startingAt: cursor, in: text) {
            return nil
        }
        guard cursor < text.endIndex else {
            return nil
        }
        let typeStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "=" || character == "(" || character == "{" || character == ";" {
                break
            }
            cursor = text.index(after: cursor)
        }
        guard typeStart < cursor else {
            return nil
        }
        let authoredTypeName = String(text[typeStart..<cursor])
        try skipPropertyDeclarationWhitespace(in: text, index: &cursor)
        let propertyNameStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || character == "=" || character == "(" || character == ";" || character == "{" {
                break
            }
            cursor = text.index(after: cursor)
        }
        guard propertyNameStart < cursor else {
            return nil
        }
        let authoredPropertyName = String(text[propertyNameStart..<cursor])
        let normalizedName = normalizedPropertyName(authoredPropertyName)
        guard !normalizedName.baseName.isEmpty else {
            return nil
        }
        guard isValidUSDPropertyName(normalizedName.baseName) else {
            throw USDError.invalidData("USDA property name \(authoredPropertyName) is not a valid identifier.")
        }
        let isListEdit = qualifiers.contains(where: isListEditQualifier)
        let listEditOperation = qualifiers.first(where: isListEditQualifier)
        let valueStart = try propertyAssignmentValueStart(afterPropertyName: cursor, in: text)
        let hasAssignment = valueStart != nil
        let assignmentValue = try valueStart.map { try propertyAssignmentValue(startingAt: $0, in: text) }
        let specType: SdfSpecType = authoredTypeName == "rel" ? .relationship : .attribute
        let propertyPath = propertyPath(parentPrimPath: parentPrimPath, propertyName: normalizedName.baseName)
        var fieldNames: Set<String> = []
        var fields: [String: USDLayerFieldValue] = [:]
        if qualifiers.contains("custom") {
            fieldNames.insert("custom")
            fields["custom"] = .authored("true")
        }
        if let variability = qualifiers.first(where: { $0 == "uniform" || $0 == "varying" }) {
            fieldNames.insert("variability")
            fields["variability"] = .authored(variability)
        }
        if let listEditOperation {
            fieldNames.insert("listEditOperation")
            fields["listEditOperation"] = .authored(listEditOperation)
        }
        let metadata = try parsePropertyMetadata(afterPropertyName: cursor, in: text)
        fieldNames.formUnion(metadata.fieldNames)
        for (metadataName, metadataValue) in metadata.fields {
            guard fields.updateValue(metadataValue, forKey: metadataName) == nil else {
                throw USDError.invalidData(
                    "USDA property \(propertyPath) metadata duplicates field \(metadataName)."
                )
            }
        }
        switch specType {
        case .relationship:
            if hasAssignment {
                fieldNames.insert("targetPaths")
                fields["targetPaths"] = try propertyPathListFieldValue(
                    operation: listEditOperation,
                    valueStart: valueStart,
                    authoredValue: assignmentValue,
                    in: text
                )
            }
        default:
            fieldNames.insert("typeName")
            fields["typeName"] = .authored(authoredTypeName)
            switch normalizedName.valueField {
            case .connectionPaths:
                fieldNames.insert("connectionPaths")
                fields["connectionPaths"] = try propertyPathListFieldValue(
                    operation: listEditOperation,
                    valueStart: valueStart,
                    authoredValue: assignmentValue,
                    in: text
                )
            case .timeSamples:
                fieldNames.insert("timeSamples")
                fields["timeSamples"] = assignmentValue.map { .authored($0) }
            case .defaultValue:
                if hasAssignment {
                    fieldNames.insert("default")
                    fields["default"] = assignmentValue.map { .authored($0) }
                }
            case nil:
                if hasAssignment {
                    fieldNames.insert("default")
                    fields["default"] = assignmentValue.map { .authored($0) }
                }
            }
        }
        if specType == .relationship,
           normalizedName.valueField == .defaultValue,
           hasAssignment {
            fieldNames.insert("targetPaths")
            fields["targetPaths"] = try propertyPathListFieldValue(
                operation: listEditOperation,
                valueStart: valueStart,
                authoredValue: assignmentValue,
                in: text
            )
        }
        let childSpecs = try childTargetSpecs(
            forPropertyPath: propertyPath,
            specType: specType,
            valueField: normalizedName.valueField,
            isListEdit: isListEdit,
            valueStart: valueStart,
            in: text
        )
        return USDAPropertySpecDeclaration(
            path: propertyPath,
            specType: specType,
            typeName: specType == .attribute ? authoredTypeName : nil,
            fieldNames: fieldNames,
            fields: fields,
            childSpecs: childSpecs
        )
    }

    private func isPropertyOrderListEdit(
        qualifiers: [String],
        startingAt cursor: String.Index,
        in text: String
    ) -> Bool {
        qualifiers.contains(where: isListEditQualifier) && token("properties", matchesAt: cursor, in: text)
    }

    private func isListEditQualifier(_ qualifier: String) -> Bool {
        qualifier == "delete"
            || qualifier == "add"
            || qualifier == "prepend"
            || qualifier == "append"
            || qualifier == "reorder"
    }

    private func propertyPathListFieldValue(
        operation: String?,
        valueStart: String.Index?,
        authoredValue: String?,
        in text: String
    ) throws -> USDLayerFieldValue? {
        guard let valueStart, authoredValue != nil else {
            return nil
        }
        let paths = try parsePropertyTargetPaths(startingAt: valueStart, in: text)
        return .pathListOperation(pathListOperation(operation: operation, items: paths))
    }

    private func parsePropertyOrderListOperation(in text: String, parentPrimPath: String) throws -> SdfListOperation<String>? {
        var cursor = text.startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var isStatementStart = true
        var operation = SdfListOperation<String>()
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }

            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel, isStatementStart {
                if character.isWhitespace {
                    cursor = text.index(after: cursor)
                    continue
                }
                if let statementOperation = try parsePropertyOrderListOperationStatement(
                    startingAt: cursor,
                    parentPrimPath: parentPrimPath,
                    in: text
                ) {
                    mergePathListOperation(statementOperation, into: &operation)
                    cursor = try statementEnd(startingAt: cursor, in: text)
                    if cursor < text.endIndex {
                        cursor = text.index(after: cursor)
                    }
                    isStatementStart = true
                    continue
                }
                isStatementStart = false
            }

            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if isAtTopLevel, character == "\n" || character == "\r" || character == ";" {
                isStatementStart = true
            }
            cursor = text.index(after: cursor)
        }
        return operation.isEmpty ? nil : operation
    }

    private func parsePropertyOrderListOperationStatement(
        startingAt index: String.Index,
        parentPrimPath: String,
        in text: String
    ) throws -> SdfListOperation<String>? {
        var cursor = index
        var qualifiers: [String] = []
        while let qualifier = propertyDeclarationQualifier(at: cursor, in: text) {
            qualifiers.append(qualifier)
            cursor = text.index(cursor, offsetBy: qualifier.count)
            try skipPropertyDeclarationWhitespace(in: text, index: &cursor)
        }
        guard let operation = qualifiers.first(where: isListEditQualifier),
              token("properties", matchesAt: cursor, in: text) else {
            return nil
        }
        cursor = text.index(cursor, offsetBy: "properties".count)
        try skipPropertyDeclarationWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "=" else {
            throw USDError.invalidData("USDA properties list-edit is missing an assignment.")
        }
        cursor = text.index(after: cursor)
        try skipPropertyValueStartWhitespace(in: text, index: &cursor)
        let items = try parsePropertyOrderItems(startingAt: cursor, parentPrimPath: parentPrimPath, in: text)
        return pathListOperation(operation: operation, items: items)
    }

    private func parsePropertyOrderItems(
        startingAt openBracket: String.Index,
        parentPrimPath: String,
        in text: String
    ) throws -> [String] {
        guard openBracket < text.endIndex, text[openBracket] == "[" else {
            throw USDError.invalidData("USDA properties list-edit must use a bracketed list value.")
        }
        let closeBracket = try matchingBracket(startingAt: openBracket, in: text)
        var cursor = text.index(after: openBracket)
        var items: [String] = []
        while cursor < closeBracket {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < closeBracket else {
                break
            }
            if text[cursor] == "," {
                cursor = text.index(after: cursor)
                continue
            }
            let item: String
            if text[cursor] == "\"" || text[cursor] == "'" {
                let quoted = try parseQuotedString(startingAt: cursor, in: text)
                item = quoted.value
                cursor = quoted.endIndex
            } else {
                let itemStart = cursor
                while cursor < closeBracket, text[cursor] != "," {
                    cursor = text.index(after: cursor)
                }
                item = trimmed(String(text[itemStart..<cursor]))
            }
            let normalized = normalizedPropertyOrderPath(item, parentPrimPath: parentPrimPath)
            if !normalized.isEmpty {
                items.append(normalized)
            }
        }
        return items
    }

    private func normalizedPropertyOrderPath(_ value: String, parentPrimPath: String) -> String {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("<"), token.hasSuffix(">") {
            token.removeFirst()
            token.removeLast()
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return ""
        }
        if token.hasPrefix(parentPrimPath + ".") || token.hasPrefix("/") {
            return token
        }
        return propertyPath(parentPrimPath: parentPrimPath, propertyName: token)
    }

    private func pathListOperation(operation: String?, items: [String]) -> SdfListOperation<String> {
        switch operation {
        case "add":
            return SdfListOperation(addedItems: items)
        case "prepend":
            return SdfListOperation(prependedItems: items)
        case "append":
            return SdfListOperation(appendedItems: items)
        case "delete":
            return SdfListOperation(deletedItems: items)
        case "reorder":
            return SdfListOperation(orderedItems: items)
        default:
            return SdfListOperation(isExplicit: true, explicitItems: items)
        }
    }

    private func propertyAssignmentValueStart(afterPropertyName cursor: String.Index, in text: String) throws -> String.Index? {
        var cursor = cursor
        while cursor < text.endIndex, text[cursor].isWhitespace {
            if text[cursor].isNewline {
                return nil
            }
            cursor = text.index(after: cursor)
        }
        if cursor < text.endIndex, text[cursor] == "(" {
            let closeParenthesis = try matchingParenthesis(startingAt: cursor, in: text)
            cursor = text.index(after: closeParenthesis)
            while cursor < text.endIndex, text[cursor].isWhitespace {
                if text[cursor].isNewline {
                    return nil
                }
                cursor = text.index(after: cursor)
            }
        }
        guard cursor < text.endIndex else {
            return nil
        }
        guard text[cursor] == "=" else {
            return nil
        }
        cursor = text.index(after: cursor)
        try skipPropertyValueStartWhitespace(in: text, index: &cursor)
        return cursor
    }

    private func propertyAssignmentValue(startingAt valueStart: String.Index, in text: String) throws -> String {
        let valueEnd = try statementEnd(startingAt: valueStart, in: text)
        return trimmed(String(text[valueStart..<valueEnd]))
    }

    private func parsePropertyMetadata(afterPropertyName cursor: String.Index, in text: String) throws -> USDAMetadataFields {
        var cursor = cursor
        while cursor < text.endIndex, text[cursor].isWhitespace {
            if text[cursor].isNewline {
                return USDAMetadataFields()
            }
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "(" else {
            return USDAMetadataFields()
        }
        let closeParenthesis = try matchingParenthesis(startingAt: cursor, in: text)
        return try parseMetadataFields(in: String(text[text.index(after: cursor)..<closeParenthesis]))
    }

    private func normalizedPropertyName(_ authoredName: String) -> (baseName: String, valueField: USDAPropertyValueField?) {
        for suffix in [(".connect", USDAPropertyValueField.connectionPaths),
                       (".timeSamples", USDAPropertyValueField.timeSamples),
                       (".default", USDAPropertyValueField.defaultValue)] {
            guard authoredName.hasSuffix(suffix.0) else {
                continue
            }
            return (String(authoredName.dropLast(suffix.0.count)), suffix.1)
        }
        return (authoredName, nil)
    }

    private func propertyPath(parentPrimPath: String, propertyName: String) -> String {
        "\(parentPrimPath).\(propertyName)"
    }

    private func childTargetSpecs(
        forPropertyPath propertyPath: String,
        specType: SdfSpecType,
        valueField: USDAPropertyValueField?,
        isListEdit: Bool,
        valueStart: String.Index?,
        in text: String
    ) throws -> [USDLayerSpec] {
        guard let valueStart, !isListEdit else {
            return []
        }
        let childSpecType: SdfSpecType?
        if specType == .relationship {
            childSpecType = .relationshipTarget
        } else if valueField == .connectionPaths {
            childSpecType = .connection
        } else {
            childSpecType = nil
        }
        guard let childSpecType else {
            return []
        }
        let targetPaths = try parsePropertyTargetPaths(startingAt: valueStart, in: text)
        var seenPaths: Set<String> = []
        return targetPaths.compactMap { targetPath in
            guard !targetPath.isEmpty else {
                return nil
            }
            let path = targetSpecPath(propertyPath: propertyPath, targetPath: targetPath)
            guard seenPaths.insert(path).inserted else {
                return nil
            }
            return USDLayerSpec(path: path, specType: childSpecType)
        }
    }

    private func parsePropertyTargetPaths(startingAt valueStart: String.Index, in text: String) throws -> [String] {
        var cursor = valueStart
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex else {
            return []
        }
        if isNoneValue(at: cursor, in: text) {
            return []
        }
        if text[cursor] == "<" {
            return [try parseAngleTargetPath(in: text, index: &cursor)]
        }
        guard text[cursor] == "[" else {
            return []
        }
        let closeBracket = try matchingBracket(startingAt: cursor, in: text)
        cursor = text.index(after: cursor)
        var targetPaths: [String] = []
        while cursor < closeBracket {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            if character == "<" {
                targetPaths.append(try parseAngleTargetPath(in: text, index: &cursor))
                continue
            }
            cursor = text.index(after: cursor)
        }
        return targetPaths
    }

    private func parseAngleTargetPath(in text: String, index: inout String.Index) throws -> String {
        guard index < text.endIndex, text[index] == "<" else {
            throw USDError.invalidData("USDA target path is missing an opening angle bracket.")
        }
        let targetStart = text.index(after: index)
        var cursor = targetStart
        while cursor < text.endIndex, text[cursor] != ">" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else {
            throw USDError.invalidData("USDA target path is unterminated.")
        }
        index = text.index(after: cursor)
        return String(text[targetStart..<cursor])
    }

    private func targetSpecPath(propertyPath: String, targetPath: String) -> String {
        "\(propertyPath)[\(targetPath)]"
    }

    private func mergePropertySpec(
        _ declaration: USDAPropertySpecDeclaration,
        into specs: inout [USDLayerSpec],
        specIndexByPath: inout [String: Int]
    ) {
        if let index = specIndexByPath[declaration.path] {
            var spec = specs[index]
            if spec.typeName == nil {
                spec.typeName = declaration.typeName
            }
            var fieldNames = Set(spec.fieldNames)
            fieldNames.formUnion(declaration.fieldNames)
            spec.fieldNames = orderedPropertyFieldNames(fieldNames)
            spec.fields = mergedFieldValues(spec.fields, with: declaration.fields)
            specs[index] = spec
            return
        }
        specIndexByPath[declaration.path] = specs.count
        specs.append(USDLayerSpec(
            path: declaration.path,
            specType: declaration.specType,
            typeName: declaration.typeName,
            fieldNames: orderedPropertyFieldNames(declaration.fieldNames),
            fields: declaration.fields
        ))
    }

    private func mergedFieldValues(
        _ existingFields: [String: USDLayerFieldValue],
        with newFields: [String: USDLayerFieldValue]
    ) -> [String: USDLayerFieldValue] {
        var fields = existingFields
        for (name, newValue) in newFields {
            guard let existingValue = fields[name] else {
                fields[name] = newValue
                continue
            }
            guard case .pathListOperation(var existingOperation) = existingValue,
                  case .pathListOperation(let newOperation) = newValue else {
                continue
            }
            mergePathListOperation(newOperation, into: &existingOperation)
            fields[name] = .pathListOperation(existingOperation)
        }
        return fields
    }

    private func mergePathListOperation(
        _ newOperation: SdfListOperation<String>,
        into operation: inout SdfListOperation<String>
    ) {
        if newOperation.isExplicit {
            operation.isExplicit = true
            operation.explicitItems = newOperation.explicitItems
        }
        appendUnique(newOperation.addedItems, to: &operation.addedItems)
        appendUnique(newOperation.prependedItems, to: &operation.prependedItems)
        appendUnique(newOperation.appendedItems, to: &operation.appendedItems)
        appendUnique(newOperation.deletedItems, to: &operation.deletedItems)
        appendUnique(newOperation.orderedItems, to: &operation.orderedItems)
    }

    private func appendUnique<Item: Equatable>(_ newItems: [Item], to items: inout [Item]) {
        for item in newItems where !items.contains(item) {
            items.append(item)
        }
    }

    private func parseMetadataFields(in text: String) throws -> USDAMetadataFields {
        var cursor = text.startIndex
        var fieldNames: [String] = []
        var fields: [String: USDLayerFieldValue] = [:]
        while cursor < text.endIndex {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            while cursor < text.endIndex, text[cursor] == ";" {
                cursor = text.index(after: cursor)
                skipWhitespaceAndLineComments(in: text, index: &cursor)
            }
            guard cursor < text.endIndex else {
                break
            }
            let nameStart = cursor
            guard let equals = try topLevelCharacter("=", startingAt: cursor, in: text) else {
                let statementLimit = try statementEnd(startingAt: cursor, in: text)
                if text[cursor] == "\"" || text[cursor] == "'" {
                    // A bare string statement inside a metadata block authors
                    // the documentation field, matching upstream USDA semantics.
                    let documentation = try parseQuotedString(startingAt: cursor, in: text)
                    var trailingCursor = documentation.endIndex
                    skipWhitespaceAndLineComments(in: text, index: &trailingCursor)
                    guard trailingCursor >= statementLimit else {
                        throw USDError.invalidData(
                            "USDA metadata block contains unexpected text after a documentation string."
                        )
                    }
                    try appendMetadataField(
                        name: "documentation",
                        value: .authored(SdfFieldValue.quoted(documentation.value)),
                        fieldNames: &fieldNames,
                        fields: &fields
                    )
                }
                cursor = statementLimit
                if cursor < text.endIndex {
                    cursor = text.index(after: cursor)
                }
                continue
            }
            let name = trimmed(String(text[nameStart..<equals]))
            cursor = text.index(after: equals)
            skipWhitespace(in: text, index: &cursor)
            let valueStart = cursor
            let valueEnd = try statementEnd(startingAt: valueStart, in: text)
            let value = trimmed(String(text[valueStart..<valueEnd]))
            guard !name.isEmpty else {
                throw USDError.invalidData("USDA metadata block contains a statement with an empty field name.")
            }
            guard !value.isEmpty else {
                throw USDError.invalidData("USDA metadata field \(name) has no value.")
            }
            if let listEdit = metadataListEditFieldName(name) {
                try mergeMetadataListEdit(
                    fieldName: listEdit.fieldName,
                    operation: listEdit.operation,
                    value: value,
                    fieldNames: &fieldNames,
                    fields: &fields
                )
            } else {
                try appendMetadataField(
                    name: name,
                    value: try metadataFieldValue(fieldName: name, authoredValue: value),
                    fieldNames: &fieldNames,
                    fields: &fields
                )
            }
            cursor = valueEnd
            if cursor < text.endIndex, text[cursor] == ";" {
                cursor = text.index(after: cursor)
            }
        }
        return USDAMetadataFields(fieldNames: fieldNames, fields: fields)
    }

    /// Appends a metadata field, rejecting duplicate keys.
    ///
    /// Upstream USDA parsing errors on duplicate metadata fields instead of
    /// silently overwriting earlier values. List-edit fields are merged via
    /// `mergeMetadataListEdit(fieldName:operation:value:fieldNames:fields:)`
    /// and do not go through this helper.
    private func appendMetadataField(
        name: String,
        value: USDLayerFieldValue,
        fieldNames: inout [String],
        fields: inout [String: USDLayerFieldValue]
    ) throws {
        guard fields.updateValue(value, forKey: name) == nil else {
            throw USDError.invalidData("USDA metadata block contains duplicate field \(name).")
        }
        fieldNames.append(name)
    }

    private func metadataFieldValue(fieldName: String, authoredValue: String) throws -> USDLayerFieldValue {
        if isStringDictionaryMetadataField(fieldName) {
            return .dictionary(try parseStringDictionary(from: authoredValue, fieldName: fieldName))
        }
        if fieldName == "relocates" {
            // Relocates use path-to-path entries that the typed dictionary
            // model cannot represent; they are validated separately by
            // validateRelocatesMetadata(in:) and kept as authored text.
            return .authored(authoredValue)
        }
        if let dictionary = try parseMetadataDictionaryIfSupported(from: authoredValue) {
            return .dictionary(dictionary)
        }
        return .authored(authoredValue)
    }

    private func isStringDictionaryMetadataField(_ fieldName: String) -> Bool {
        fieldName == "prefixSubstitutions" || fieldName == "suffixSubstitutions"
    }

    private func parseMetadataDictionaryIfSupported(from authoredValue: String) throws -> [String: SdfFieldValue]? {
        let value = trimmed(authoredValue)
        guard value.first == "{" else {
            return nil
        }
        do {
            return try parseSdfDictionary(from: value)
        } catch let error as USDError {
            switch error {
            case .unsupportedFeature:
                // Entry types the typed dictionary model cannot represent are
                // preserved as authored text by the caller.
                return nil
            case .invalidData,
                 .missingRequiredField,
                 .notImplemented:
                throw error
            }
        }
    }

    private func metadataListEditFieldName(_ name: String) -> (operation: USDAListEditOperation, fieldName: String)? {
        let trimmedName = trimmed(name)
        for operation in USDAListEditOperation.qualifiedOperations {
            let prefix = "\(operation.rawValue) "
            guard trimmedName.hasPrefix(prefix) else {
                continue
            }
            guard let fieldName = typedMetadataListEditFieldName(trimmed(String(trimmedName.dropFirst(prefix.count)))) else {
                return nil
            }
            return (operation, fieldName)
        }
        guard let fieldName = typedMetadataListEditFieldName(trimmedName) else {
            return nil
        }
        return (.explicit, fieldName)
    }

    private func typedMetadataListEditFieldName(_ authoredName: String) -> String? {
        switch authoredName {
        case "references", "payload", "apiSchemas", "specializes":
            return authoredName
        case "variantSets":
            return "variantSetNames"
        case "inherits":
            return "inheritPaths"
        default:
            return nil
        }
    }

    private func mergeMetadataListEdit(
        fieldName: String,
        operation: USDAListEditOperation,
        value: String,
        fieldNames: inout [String],
        fields: inout [String: USDLayerFieldValue]
    ) throws {
        if !fieldNames.contains(fieldName) {
            fieldNames.append(fieldName)
        }
        switch fieldName {
        case "inheritPaths", "specializes":
            var listOperation: SdfListOperation<String>
            if case .pathListOperation(let existing)? = fields[fieldName] {
                listOperation = existing
            } else {
                listOperation = SdfListOperation()
            }
            let items = try parsePrimPathListEditItems(in: value, fieldName: fieldName)
            if operation != .explicit && items.isEmpty {
                throw USDError.invalidData("USDA \(fieldName) list-edit cannot use None or an empty list.")
            }
            try mergeListEditItems(
                items,
                operation: operation,
                into: &listOperation
            )
            fields[fieldName] = .pathListOperation(listOperation)
        case "apiSchemas":
            var listOperation: SdfListOperation<String>
            if case .tokenListOperation(let existing)? = fields[fieldName] {
                listOperation = existing
            } else {
                listOperation = SdfListOperation()
            }
            try mergeListEditItems(
                try parseStringListEditItems(in: value),
                operation: operation,
                into: &listOperation
            )
            fields[fieldName] = .tokenListOperation(listOperation)
        case "variantSetNames":
            var listOperation: SdfListOperation<String>
            if case .stringListOperation(let existing)? = fields[fieldName] {
                listOperation = existing
            } else {
                listOperation = SdfListOperation()
            }
            let items = try parseStringListEditItems(in: value)
            if operation != .explicit && items.isEmpty {
                throw USDError.invalidData("USDA variantSets list-edit cannot use None or an empty list.")
            }
            try validateVariantSetNames(items)
            try mergeListEditItems(
                items,
                operation: operation,
                into: &listOperation
            )
            fields[fieldName] = .stringListOperation(listOperation)
        case "references":
            var listOperation: SdfListOperation<SdfReference>
            if case .referenceListOperation(let existing)? = fields[fieldName] {
                listOperation = existing
            } else {
                listOperation = SdfListOperation()
            }
            try mergeListEditItems(
                try parseSdfReferences(in: value),
                operation: operation,
                into: &listOperation
            )
            fields[fieldName] = .referenceListOperation(listOperation)
        case "payload":
            var listOperation: SdfListOperation<SdfPayload>
            if case .payloadListOperation(let existing)? = fields[fieldName] {
                listOperation = existing
            } else {
                listOperation = SdfListOperation()
            }
            try mergeListEditItems(
                try parseSdfPayloads(in: value),
                operation: operation,
                into: &listOperation
            )
            fields[fieldName] = .payloadListOperation(listOperation)
        default:
            fields[fieldName] = .authored(value)
        }
    }

    private func parseStringListEditItems(in value: String) throws -> [String] {
        let value = trimmed(value)
        guard !value.isEmpty, !isNoneValue(at: value.startIndex, in: value) else {
            return []
        }
        guard value[value.startIndex] == "[" else {
            return [try stringLikeCustomDataValue(value)]
        }
        return try stringArrayValue(value)
    }

    private func validateVariantSetNames(_ names: [String]) throws {
        for name in names {
            guard isValidUSDIdentifier(name) else {
                throw USDError.invalidData("USDA variantSets item \(name) is not a valid variant set identifier.")
            }
        }
    }

    private func parsePrimPathListEditItems(in value: String, fieldName: String) throws -> [String] {
        let value = trimmed(value)
        guard !value.isEmpty, !isNoneValue(at: value.startIndex, in: value) else {
            return []
        }
        if value[value.startIndex] == "[" {
            let closeBracket = try matchingBracket(startingAt: value.startIndex, in: value)
            guard trimmed(String(value[value.index(after: closeBracket)..<value.endIndex])).isEmpty else {
                throw USDError.invalidData("USDA \(fieldName) list contains trailing content.")
            }
            let body = String(value[value.index(after: value.startIndex)..<closeBracket])
            return try commaSeparatedTopLevelValues(in: body).map {
                try parsePrimPathListEditItem($0, fieldName: fieldName)
            }
        }
        return [try parsePrimPathListEditItem(value, fieldName: fieldName)]
    }

    private func parsePrimPathListEditItem(_ value: String, fieldName: String) throws -> String {
        let value = trimmed(value)
        guard !value.isEmpty, value[value.startIndex] == "<" else {
            throw USDError.invalidData("USDA \(fieldName) path list item must be a path reference.")
        }
        guard let closeAngle = value.firstIndex(of: ">") else {
            throw USDError.invalidData("USDA \(fieldName) path list item is unterminated.")
        }
        guard trimmed(String(value[value.index(after: closeAngle)..<value.endIndex])).isEmpty else {
            throw USDError.invalidData("USDA \(fieldName) path list item contains trailing content.")
        }
        let path = try SdfPath(String(value[value.index(after: value.startIndex)..<closeAngle]))
        guard path.isAbsolute, path.kind == .prim, !path.containsVariantSelection else {
            throw USDError.invalidData("USDA \(fieldName) paths must be absolute prim paths without variant selections.")
        }
        return path.rawValue
    }

    private func mergeListEditItems<Item: Sendable & Equatable & Hashable>(
        _ items: [Item],
        operation: USDAListEditOperation,
        into listOperation: inout SdfListOperation<Item>
    ) throws {
        switch operation {
        case .explicit:
            listOperation.isExplicit = true
            listOperation.explicitItems = items
        case .add:
            appendUnique(items, to: &listOperation.addedItems)
        case .prepend:
            appendUnique(items, to: &listOperation.prependedItems)
        case .append:
            appendUnique(items, to: &listOperation.appendedItems)
        case .delete:
            appendUnique(items, to: &listOperation.deletedItems)
        case .reorder:
            appendUnique(items, to: &listOperation.orderedItems)
        }
    }

    private func topLevelCharacter(_ target: Character, startingAt startIndex: String.Index, in text: String) throws -> String.Index? {
        var cursor = startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if parenthesisDepth == 0,
               bracketDepth == 0,
               braceDepth == 0,
               character == target {
                return cursor
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                if parenthesisDepth == 0 {
                    return nil
                }
                parenthesisDepth -= 1
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                if bracketDepth == 0 {
                    return nil
                }
                bracketDepth -= 1
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                if braceDepth == 0 {
                    return nil
                }
                braceDepth -= 1
            } else if parenthesisDepth == 0,
                      bracketDepth == 0,
                      braceDepth == 0,
                      (character == "\n" || character == "\r" || character == ";") {
                return nil
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private func statementEnd(startingAt startIndex: String.Index, in text: String) throws -> String.Index {
        var cursor = startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if parenthesisDepth == 0,
               bracketDepth == 0,
               braceDepth == 0,
               (character == "\n" || character == "\r" || character == ";") {
                return cursor
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                if parenthesisDepth == 0 {
                    return cursor
                }
                parenthesisDepth -= 1
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                if bracketDepth == 0 {
                    return cursor
                }
                bracketDepth -= 1
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                if braceDepth == 0 {
                    return cursor
                }
                braceDepth -= 1
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func specifierKeyword(_ specifier: SdfSpecifier) -> String {
        switch specifier {
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

    private func quotedAuthoredString(_ value: String) -> String {
        SdfFieldValue.quoted(value)
    }

    private func mergeLayerSpec(
        _ newSpec: USDLayerSpec,
        into specs: inout [USDLayerSpec],
        specIndexByPath: inout [String: Int]
    ) {
        if let index = specIndexByPath[newSpec.path] {
            var spec = specs[index]
            var fieldNames = Set(spec.fieldNames)
            fieldNames.formUnion(newSpec.fieldNames)
            spec.fieldNames = orderedPropertyFieldNames(fieldNames)
            spec.fields = mergedFieldValues(spec.fields, with: newSpec.fields)
            specs[index] = spec
            return
        }
        specIndexByPath[newSpec.path] = specs.count
        specs.append(newSpec)
    }

    private func orderedPropertyFieldNames(_ fieldNames: Set<String>) -> [String] {
        let preferredOrder = [
            "custom",
            "listEditOperation",
            "typeName",
            "variability",
            "default",
            "connectionPaths",
            "timeSamples",
            "targetPaths",
        ]
        var ordered = preferredOrder.filter { fieldNames.contains($0) }
        ordered.append(contentsOf: fieldNames.subtracting(preferredOrder).sorted())
        return ordered
    }

    private func parsePrimTransforms(prims: [USDAPrim]) throws -> [String: USDTransformMatrix4x4] {
        try parsePrimTransforms(prims: prims, inheritedTransform: .identity, parentPrimPath: "")
    }

    private func parseResetXformStackPrimPaths(prims: [USDAPrim]) throws -> Set<String> {
        try parseResetXformStackPrimPaths(prims: prims, parentPrimPath: "")
    }

    private func parseResetXformStackPrimPaths(
        prims: [USDAPrim],
        parentPrimPath: String
    ) throws -> Set<String> {
        var resetPrimPaths: Set<String> = []
        for prim in prims {
            let primPath = primPath(for: prim, parentPrimPath: parentPrimPath)
            let directBody = try directAttributeText(from: prim.body)
            let localTransform = try parseLocalTransform(in: directBody)
            if localTransform.resetsParentStack {
                resetPrimPaths.insert(primPath)
            }
            let childResetPrimPaths = try parseResetXformStackPrimPaths(
                prims: parseDirectPrims(in: prim.body),
                parentPrimPath: primPath
            )
            resetPrimPaths.formUnion(childResetPrimPaths)
        }
        return resetPrimPaths
    }

    private func parsePrimTransforms(
        prims: [USDAPrim],
        inheritedTransform: USDTransformMatrix4x4,
        parentPrimPath: String
    ) throws -> [String: USDTransformMatrix4x4] {
        var primTransforms: [String: USDTransformMatrix4x4] = [:]
        for prim in prims {
            let primPath = primPath(for: prim, parentPrimPath: parentPrimPath)
            let directBody = try directAttributeText(from: prim.body)
            let localTransform = try parseLocalTransform(in: directBody)
            let primTransform: USDTransformMatrix4x4
            if localTransform.resetsParentStack {
                primTransform = localTransform.matrix
            } else {
                primTransform = try localTransform.matrix.concatenating(inheritedTransform)
            }
            primTransforms[primPath] = primTransform
            let childTransforms = try parsePrimTransforms(
                prims: parseDirectPrims(in: prim.body),
                inheritedTransform: primTransform,
                parentPrimPath: primPath
            )
            primTransforms.merge(childTransforms) { _, new in new }
        }
        return primTransforms
    }

    private func parseMeshes(
        prims: [USDAPrim],
        options: USDReadingOptions,
        inheritedTransform: USDTransformMatrix4x4,
        parentPrimPath: String
    ) throws -> [USDMesh] {
        var meshes: [USDMesh] = []
        for prim in prims {
            let primPath = primPath(for: prim, parentPrimPath: parentPrimPath)
            let directBody = try directAttributeText(from: prim.body)
            let localTransform = try parseLocalTransform(in: directBody)
            let primTransform: USDTransformMatrix4x4
            if localTransform.resetsParentStack {
                primTransform = localTransform.matrix
            } else {
                primTransform = try localTransform.matrix.concatenating(inheritedTransform)
            }
            if prim.specifier == .def, prim.typeName == "Mesh" {
                meshes.append(try materializeMesh(
                    prim: prim,
                    primPath: primPath,
                    directBody: directBody,
                    options: options,
                    transform: primTransform
                ))
            }
            meshes.append(contentsOf: try parseMeshes(
                prims: parseDirectPrims(in: prim.body),
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
        try USDMesh.validateTopology(
            pointCount: transformedPoints.count,
            faceVertexCounts: counts,
            faceVertexIndices: indices
        )
        let normals = try parseOptionalPointArray(named: "normals", in: directBody, options: options) ?? []
        let transformedNormals = try normals.map { try transform.transform(normal: $0) }
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
        let extent = try parseOptionalPointArray(named: "extent", in: directBody, options: options)
        if let extent, extent.count != 2 {
            throw USDError.invalidData("USDA extent must contain exactly two points.")
        }
        let transformedExtent = try transformedExtent(extent, applying: transform)
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
            extent: transformedExtent
        )
    }

    private func transformedExtent(
        _ extent: [USDPoint3D]?,
        applying transform: USDTransformMatrix4x4
    ) throws -> [USDPoint3D]? {
        guard let extent else {
            return nil
        }
        let minimum = extent[0]
        let maximum = extent[1]
        let corners = [
            USDPoint3D(x: minimum.x, y: minimum.y, z: minimum.z),
            USDPoint3D(x: maximum.x, y: minimum.y, z: minimum.z),
            USDPoint3D(x: minimum.x, y: maximum.y, z: minimum.z),
            USDPoint3D(x: minimum.x, y: minimum.y, z: maximum.z),
            USDPoint3D(x: maximum.x, y: maximum.y, z: minimum.z),
            USDPoint3D(x: maximum.x, y: minimum.y, z: maximum.z),
            USDPoint3D(x: minimum.x, y: maximum.y, z: maximum.z),
            USDPoint3D(x: maximum.x, y: maximum.y, z: maximum.z),
        ]
        let transformedCorners = try corners.map { try transform.transform($0) }
        let xs = transformedCorners.map(\.x)
        let ys = transformedCorners.map(\.y)
        let zs = transformedCorners.map(\.z)
        guard let minX = xs.min(),
              let minY = ys.min(),
              let minZ = zs.min(),
              let maxX = xs.max(),
              let maxY = ys.max(),
              let maxZ = zs.max() else {
            return nil
        }
        return [
            USDPoint3D(x: minX, y: minY, z: minZ),
            USDPoint3D(x: maxX, y: maxY, z: maxZ),
        ]
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
        while let declaration = try nextDirectDeclaration(in: text, from: searchIndex, matching: [.prim]) {
            let prim = try parsePrim(at: declaration.index, in: text)
            prims.append(prim)
            searchIndex = prim.fullRange.upperBound
        }
        return prims
    }

    private func directAttributeText(from text: String) throws -> String {
        var output = ""
        var searchIndex = text.startIndex
        while let declaration = try nextDirectDeclaration(in: text, from: searchIndex, matching: [.prim, .variantSet]) {
            let declarationEnd: String.Index
            switch declaration.kind {
            case .prim:
                declarationEnd = try parsePrim(at: declaration.index, in: text).fullRange.upperBound
            case .variantSet:
                declarationEnd = try parseVariantSet(at: declaration.index, in: text).fullRange.upperBound
            }
            output += String(text[searchIndex..<declaration.index])
            searchIndex = declarationEnd
        }
        output += String(text[searchIndex..<text.endIndex])
        return output
    }

    /// Finds the next direct (depth-zero) declaration of one of the requested
    /// kinds. All callers share this single scanner so every scan applies the
    /// same lexical skipping rules (comments, quoted strings, asset-path
    /// literals); per-kind scanner copies have historically diverged on those
    /// rules. When both kinds are requested they are probed within one scan:
    /// probing each kind with a separate scan rescans the remaining body once
    /// per declaration, which is quadratic on bodies with many children.
    private func nextDirectDeclaration(
        in text: String,
        from startIndex: String.Index,
        matching kinds: Set<USDADirectDeclarationKind>
    ) throws -> (kind: USDADirectDeclarationKind, index: String.Index)? {
        // Scan over Unicode scalars rather than grapheme-cluster Characters.
        // Outside quoted strings, asset paths, and comments (all delegated to
        // skip helpers) USDA structure is ASCII, so scalar boundaries coincide
        // with grapheme boundaries while avoiding per-character grapheme
        // validation on every step. String.Index is shared across both views.
        let scalars = text.unicodeScalars
        var index = startIndex
        var braceDepth = 0
        var bracketDepth = 0
        var parenthesisDepth = 0
        while index < text.endIndex {
            let character = scalars[index]
            if character == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &index)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &index)
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
                      parenthesisDepth == 0 {
                // A declaration keyword can only begin with one of these ASCII
                // letters (class/over/def/variantSet), so gating on the current
                // scalar skips the probe for every other character. The probe
                // functions still apply the authoritative leading/trailing
                // boundary rules, so this only filters out guaranteed misses.
                switch character {
                case "c", "o", "d", "v":
                    if kinds.contains(.prim), primDeclarationKeyword(at: index, in: text) != nil {
                        return (.prim, index)
                    }
                    if kinds.contains(.variantSet), variantSetDeclarationKeyword(at: index, in: text) != nil {
                        return (.variantSet, index)
                    }
                default:
                    break
                }
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    private func parsePrim(at declarationIndex: String.Index, in text: String) throws -> USDAPrim {
        guard let keyword = primDeclarationKeyword(at: declarationIndex, in: text) else {
            throw USDError.invalidData("USDA prim declaration has an unsupported specifier.")
        }
        let specifier = try primSpecifier(for: keyword)
        let scalars = text.unicodeScalars
        var cursor = scalars.index(declarationIndex, offsetBy: keyword.count)
        try skipPrimDeclarationWhitespace(in: text, index: &cursor)
        var typeName: String?
        let name: String?
        if cursor < text.endIndex, scalars[cursor] == "\"" {
            let quoted = try parseQuotedString(startingAt: cursor, in: text)
            name = quoted.value
            cursor = quoted.endIndex
        } else {
            let typeStart = cursor
            while cursor < text.endIndex,
                  !isWhitespaceScalar(scalars[cursor]),
                  scalars[cursor] != "\"",
                  scalars[cursor] != "(",
                  scalars[cursor] != "{" {
                cursor = scalars.index(after: cursor)
            }
            guard typeStart < cursor else {
                throw USDError.invalidData("USDA prim declaration is missing a type name.")
            }
            typeName = String(text[typeStart..<cursor])
            try skipPrimDeclarationWhitespace(in: text, index: &cursor)
            guard cursor < text.endIndex, scalars[cursor] == "\"" else {
                throw USDError.invalidData("USDA prim declaration is missing a quoted name.")
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
        if cursor < text.endIndex, scalars[cursor] == "(" {
            let metadataEnd = try matchingParenthesis(startingAt: cursor, in: text)
            metadataBody = String(text[scalars.index(after: cursor)..<metadataEnd])
            cursor = scalars.index(after: metadataEnd)
        } else {
            metadataBody = ""
        }

        skipWhitespaceAndLineComments(in: text, index: &cursor)
        guard cursor < text.endIndex else {
            throw USDError.invalidData("USDA prim is missing an opening brace.")
        }
        guard scalars[cursor] == "{" else {
            throw USDError.invalidData("USDA prim declaration contains unexpected token before body.")
        }
        let openBrace = cursor
        let closeBrace = try matchingBrace(startingAt: openBrace, in: text)
        let body = String(text[scalars.index(after: openBrace)..<closeBrace])
        return USDAPrim(
            specifier: specifier,
            typeName: typeName,
            name: name,
            metadataBody: metadataBody,
            body: body,
            fullRange: declarationIndex..<scalars.index(after: closeBrace)
        )
    }

    private func primSpecifier(for keyword: String) throws -> SdfSpecifier {
        switch keyword {
        case "def":
            return .def
        case "over":
            return .over
        case "class":
            return .class
        default:
            throw USDError.invalidData("USDA prim declaration has an unsupported specifier.")
        }
    }

    private func parseVariantSetSpecs(in text: String, parentPrimPath: String) throws -> [USDLayerSpec] {
        var specs: [USDLayerSpec] = []
        var searchIndex = text.startIndex
        while let declaration = try nextDirectDeclaration(in: text, from: searchIndex, matching: [.variantSet]) {
            let variantSet = try parseVariantSet(at: declaration.index, in: text)
            let variantSetPath = "\(parentPrimPath){\(variantSet.name)}"
            let variantSpecs = try parseVariantSpecs(
                in: variantSet.body,
                parentPrimPath: parentPrimPath,
                variantSetName: variantSet.name
            )
            var fields: [String: USDLayerFieldValue] = [
                "name": .authored(quotedAuthoredString(variantSet.name)),
            ]
            var fieldNames = ["name"]
            if variantSpecs.isEmpty {
                fieldNames.append("body")
                fields["body"] = .authored(trimmed(variantSet.body))
            }
            specs.append(USDLayerSpec(
                path: variantSetPath,
                specType: .variantSet,
                fieldNames: fieldNames,
                fields: fields
            ))
            specs.append(contentsOf: variantSpecs)
            searchIndex = variantSet.fullRange.upperBound
        }
        return specs
    }

    private func variantSetSpecsMaterializedFromMetadata(
        _ fieldValue: USDLayerFieldValue?,
        parentPrimPath: String,
        existingSpecs: [USDLayerSpec]
    ) -> [USDLayerSpec] {
        guard case .stringListOperation(let operation)? = fieldValue else {
            return []
        }
        let existingNames = Set(existingSpecs.compactMap { spec -> String? in
            guard spec.specType == .variantSet else {
                return nil
            }
            return variantSetName(for: spec.path)
        })
        var names: [String] = []
        var seenNames: Set<String> = []
        // Every list-edit form that introduces a variant set materializes a spec.
        for name in operation.explicitItems
            + operation.addedItems
            + operation.prependedItems
            + operation.appendedItems
            where seenNames.insert(name).inserted {
            names.append(name)
        }
        return names.filter { !existingNames.contains($0) }.map { name in
            USDLayerSpec(
                path: "\(parentPrimPath){\(name)}",
                specType: .variantSet,
                fieldNames: ["name"],
                fields: ["name": .authored(quotedAuthoredString(name))]
            )
        }
    }

    private func variantSetName(for path: String) -> String {
        guard let openBrace = path.lastIndex(of: "{"),
              let closeBrace = path.lastIndex(of: "}") else {
            return ""
        }
        return String(path[path.index(after: openBrace)..<closeBrace])
    }

    private func parseVariantSpecs(
        in text: String,
        parentPrimPath: String,
        variantSetName: String
    ) throws -> [USDLayerSpec] {
        var specs: [USDLayerSpec] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex else {
                break
            }
            guard text[cursor] == "\"" || text[cursor] == "'" else {
                cursor = text.index(after: cursor)
                continue
            }
            let variantName = try parseQuotedString(startingAt: cursor, in: text)
            cursor = variantName.endIndex
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex, text[cursor] == "{" else {
                continue
            }
            let closeBrace = try matchingBrace(startingAt: cursor, in: text)
            let body = String(text[text.index(after: cursor)..<closeBrace])
            let variantPath = "\(parentPrimPath){\(variantSetName)=\(variantName.value)}"
            let bodySpecs = try parseVariantBodySpecs(in: body, variantPath: variantPath)
            var fields: [String: USDLayerFieldValue] = [
                "name": .authored(quotedAuthoredString(variantName.value)),
            ]
            var fieldNames = ["name"]
            if bodySpecs.isFullyMaterialized {
                if let propertyOrderOperation = bodySpecs.propertyOrderOperation {
                    fieldNames.append("properties")
                    fields["properties"] = .pathListOperation(propertyOrderOperation)
                } else if !bodySpecs.propertySpecs.isEmpty {
                    fieldNames.append("properties")
                    fields["properties"] = .authored(bodySpecs.propertySpecs.map(\.path).joined(separator: ", "))
                }
            } else {
                fieldNames.append("body")
                fields["body"] = .authored(trimmed(body))
            }
            specs.append(USDLayerSpec(
                path: variantPath,
                specType: .variant,
                fieldNames: fieldNames,
                fields: fields
            ))
            if bodySpecs.isFullyMaterialized {
                specs.append(contentsOf: bodySpecs.propertySpecs)
                specs.append(contentsOf: bodySpecs.variantSetSpecs)
                specs.append(contentsOf: bodySpecs.childPrimSpecs)
            }
            cursor = text.index(after: closeBrace)
        }
        return specs
    }

    private func parseVariantBodySpecs(in body: String, variantPath: String) throws -> USDAVariantBodySpecs {
        let directBody = try directAttributeText(from: body)
        let propertySpecs = try parsePropertySpecs(in: directBody, parentPrimPath: variantPath)
        let propertyOrderOperation = try parsePropertyOrderListOperation(in: directBody, parentPrimPath: variantPath)
        let variantSetSpecs = try parseVariantSetSpecs(in: body, parentPrimPath: variantPath)
        let childPrimSpecs = try parseLayerSpecs(from: parseDirectPrims(in: body), parentPrimPath: variantPath)
        let hasStructuredSpecs = propertyOrderOperation != nil
            || !propertySpecs.isEmpty
            || !variantSetSpecs.isEmpty
            || !childPrimSpecs.isEmpty
        guard hasStructuredSpecs else {
            return USDAVariantBodySpecs(isFullyMaterialized: false)
        }
        guard try directVariantBodyContainsOnlyMaterializedPropertyStatements(directBody, parentPrimPath: variantPath) else {
            return USDAVariantBodySpecs(isFullyMaterialized: false)
        }
        return USDAVariantBodySpecs(
            isFullyMaterialized: true,
            propertySpecs: propertySpecs,
            propertyOrderOperation: propertyOrderOperation,
            variantSetSpecs: variantSetSpecs,
            childPrimSpecs: childPrimSpecs
        )
    }

    private func directVariantBodyContainsOnlyMaterializedPropertyStatements(
        _ text: String,
        parentPrimPath: String
    ) throws -> Bool {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            while cursor < text.endIndex, text[cursor] == ";" {
                cursor = text.index(after: cursor)
                skipWhitespaceAndLineComments(in: text, index: &cursor)
            }
            guard cursor < text.endIndex else {
                return true
            }
            let statementStart = cursor
            var qualifierCursor = cursor
            var qualifiers: [String] = []
            while let qualifier = propertyDeclarationQualifier(at: qualifierCursor, in: text) {
                qualifiers.append(qualifier)
                qualifierCursor = text.index(qualifierCursor, offsetBy: qualifier.count)
                try skipPropertyDeclarationWhitespace(in: text, index: &qualifierCursor)
            }
            let isMaterialized: Bool
            if isPropertyOrderListEdit(qualifiers: qualifiers, startingAt: qualifierCursor, in: text) {
                isMaterialized = try parsePropertyOrderListOperationStatement(
                    startingAt: statementStart,
                    parentPrimPath: parentPrimPath,
                    in: text
                ) != nil
            } else {
                isMaterialized = try parsePropertySpecDeclaration(
                    startingAt: statementStart,
                    parentPrimPath: parentPrimPath,
                    in: text
                ) != nil
            }
            guard isMaterialized else {
                return false
            }
            cursor = try statementEnd(startingAt: statementStart, in: text)
            if cursor < text.endIndex {
                cursor = text.index(after: cursor)
            }
        }
        return true
    }

    private func parseVariantSet(at declarationIndex: String.Index, in text: String) throws -> USDAVariantSet {
        guard variantSetDeclarationKeyword(at: declarationIndex, in: text) != nil else {
            throw USDError.invalidData("USDA variant set declaration is malformed.")
        }
        var cursor = text.index(declarationIndex, offsetBy: "variantSet".count)
        try skipPrimDeclarationWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "\"" || text[cursor] == "'" else {
            throw USDError.invalidData("USDA variant set declaration is missing a quoted name.")
        }
        let name = try parseQuotedString(startingAt: cursor, in: text)
        cursor = name.endIndex
        skipWhitespace(in: text, index: &cursor)
        if cursor < text.endIndex, text[cursor] == "=" {
            cursor = text.index(after: cursor)
            skipWhitespace(in: text, index: &cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "{" else {
            throw USDError.invalidData("USDA variant set declaration is missing a body.")
        }
        let closeBrace = try matchingBrace(startingAt: cursor, in: text)
        return USDAVariantSet(
            name: name.value,
            body: String(text[text.index(after: cursor)..<closeBrace]),
            fullRange: declarationIndex..<text.index(after: closeBrace)
        )
    }

    private func parseQuotedString(
        startingAt quoteStart: String.Index,
        in text: String
    ) throws -> (value: String, endIndex: String.Index) {
        guard quoteStart < text.endIndex,
              text[quoteStart] == "\"" || text[quoteStart] == "'" else {
            throw USDError.invalidData("USDA string is missing an opening quote.")
        }
        let quote = text.unicodeScalars[quoteStart]
        let delimiterLength = repeatedCharacterCount(at: quoteStart, character: quote, in: text) >= 3 ? 3 : 1
        var cursor = text.index(quoteStart, offsetBy: delimiterLength)
        var value = ""
        while cursor < text.endIndex {
            if text[cursor] == "\\" {
                cursor = text.index(after: cursor)
                guard cursor < text.endIndex else {
                    throw USDError.invalidData("USDA string is unterminated.")
                }
                try appendDecodedEscapeSequence(to: &value, in: text, cursor: &cursor)
                continue
            }
            if repeatedCharacterCount(at: cursor, character: quote, in: text) >= delimiterLength {
                return (
                    value,
                    text.index(cursor, offsetBy: delimiterLength)
                )
            }
            value.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        throw USDError.invalidData("USDA string is unterminated.")
    }

    /// Decodes the escape sequence whose introducing backslash has already
    /// been consumed; `cursor` points at the escape character.
    ///
    /// Supports the escapes accepted by upstream USD's quoted-string
    /// evaluation (TfEscapeString): `\\`, `\"`, `\'`, `\n`, `\t`, `\r`,
    /// `\a`, `\b`, `\f`, `\v`, hexadecimal `\xHH`, octal `\NNN`, and a
    /// backslash-newline line continuation. Any other escaped character is
    /// kept literally with the backslash dropped, matching upstream.
    private func appendDecodedEscapeSequence(
        to value: inout String,
        in text: String,
        cursor: inout String.Index
    ) throws {
        let escapeCharacter = text[cursor]
        cursor = text.index(after: cursor)
        switch escapeCharacter {
        case "n":
            value.append("\n")
        case "t":
            value.append("\t")
        case "r":
            value.append("\r")
        case "a":
            value.append("\u{07}")
        case "b":
            value.append("\u{08}")
        case "f":
            value.append("\u{0C}")
        case "v":
            value.append("\u{0B}")
        case "\n":
            // Backslash-newline is a line continuation and produces nothing.
            break
        case "x":
            var digits = ""
            while cursor < text.endIndex, digits.count < 2, text[cursor].isHexDigit {
                digits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard let scalarValue = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(scalarValue) else {
                throw USDError.invalidData(
                    "USDA string contains a malformed hexadecimal escape sequence."
                )
            }
            value.unicodeScalars.append(scalar)
        case "0"..."7":
            var digits = String(escapeCharacter)
            while cursor < text.endIndex, digits.count < 3, ("0"..."7").contains(text[cursor]) {
                digits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard let scalarValue = UInt32(digits, radix: 8),
                  let scalar = Unicode.Scalar(scalarValue) else {
                throw USDError.invalidData(
                    "USDA string contains a malformed octal escape sequence."
                )
            }
            value.unicodeScalars.append(scalar)
        default:
            // Includes \\, \", and \' as well as unrecognized escapes,
            // which upstream keeps literally with the backslash dropped.
            value.append(escapeCharacter)
        }
    }

    private func validatePrimName(_ name: String) throws {
        guard isValidUSDIdentifier(name) else {
            throw USDError.invalidData("USDA prim name \(name) is not a valid identifier.")
        }
    }

    private func isValidUSDIdentifier(_ name: String) -> Bool {
        let substring: Substring = name[...]
        return isValidUSDIdentifier(substring)
    }

    private func isValidUSDIdentifier(_ name: Substring) -> Bool {
        guard let firstScalar = name.unicodeScalars.first else {
            return false
        }
        guard firstScalar.value == 0x5f || firstScalar.properties.isXIDStart else {
            return false
        }
        for scalar in name.unicodeScalars.dropFirst() {
            guard scalar.properties.isXIDContinue else {
                return false
            }
        }
        return true
    }

    private func isValidUSDPropertyTypeName(_ name: String) -> Bool {
        var componentStart = name.startIndex
        var cursor = name.startIndex
        var hasNamespaceSeparator = false

        while cursor < name.endIndex {
            if name[cursor] == ":" {
                guard componentStart < cursor else {
                    return false
                }
                guard isValidUSDIdentifier(name[componentStart..<cursor]) else {
                    return false
                }
                let next = name.index(after: cursor)
                guard next < name.endIndex, name[next] == ":" else {
                    return false
                }
                let afterSeparator = name.index(after: next)
                guard afterSeparator < name.endIndex else {
                    return false
                }
                hasNamespaceSeparator = true
                componentStart = afterSeparator
                cursor = afterSeparator
            } else {
                cursor = name.index(after: cursor)
            }
        }

        guard componentStart < name.endIndex else {
            return false
        }
        let finalComponent = name[componentStart..<name.endIndex]
        if hasNamespaceSeparator {
            return isValidUSDIdentifier(finalComponent)
        }
        return isValidUSDIdentifier(name)
    }

    private func isValidUSDPropertyName(_ name: String) -> Bool {
        var componentStart = name.startIndex
        var cursor = name.startIndex
        while cursor < name.endIndex {
            if name[cursor] == ":" {
                guard componentStart < cursor,
                      isValidUSDIdentifier(name[componentStart..<cursor]) else {
                    return false
                }
                componentStart = name.index(after: cursor)
            }
            cursor = name.index(after: cursor)
        }
        guard componentStart < name.endIndex else {
            return false
        }
        return isValidUSDIdentifier(name[componentStart..<name.endIndex])
    }

    /// Scalar-level prefix match for an ASCII keyword. USDA keywords are pure
    /// ASCII, so comparing scalars avoids grapheme-cluster subscripting.
    private func matchesASCIIKeyword(
        _ keyword: String,
        at index: String.Index,
        in scalars: String.UnicodeScalarView
    ) -> Bool {
        var cursor = index
        for keywordScalar in keyword.unicodeScalars {
            guard cursor < scalars.endIndex, scalars[cursor] == keywordScalar else {
                return false
            }
            cursor = scalars.index(after: cursor)
        }
        return true
    }

    private func hasKeywordLeadingBoundary(at index: String.Index, in scalars: String.UnicodeScalarView) -> Bool {
        guard index != scalars.startIndex else {
            return true
        }
        let previous = scalars[scalars.index(before: index)]
        return isWhitespaceScalar(previous) || previous == "{" || previous == "}" || previous == ";"
    }

    private func primDeclarationKeyword(at index: String.Index, in text: String) -> String? {
        let scalars = text.unicodeScalars
        let keywords = ["class", "over", "def"]
        guard let keyword = keywords.first(where: { matchesASCIIKeyword($0, at: index, in: scalars) }) else {
            return nil
        }
        guard let keywordEnd = scalars.index(index, offsetBy: keyword.count, limitedBy: scalars.endIndex) else {
            return nil
        }
        let hasTrailingBoundary = keywordEnd == scalars.endIndex || isWhitespaceScalar(scalars[keywordEnd])
        return hasKeywordLeadingBoundary(at: index, in: scalars) && hasTrailingBoundary ? keyword : nil
    }

    private func variantSetDeclarationKeyword(at index: String.Index, in text: String) -> String? {
        let scalars = text.unicodeScalars
        let keyword = "variantSet"
        guard matchesASCIIKeyword(keyword, at: index, in: scalars),
              let keywordEnd = scalars.index(index, offsetBy: keyword.count, limitedBy: scalars.endIndex) else {
            return nil
        }
        let hasTrailingBoundary = keywordEnd == scalars.endIndex || isWhitespaceScalar(scalars[keywordEnd])
        return hasKeywordLeadingBoundary(at: index, in: scalars) && hasTrailingBoundary ? keyword : nil
    }

    /// True when the scalar is whitespace under the same rule as
    /// `Character.isWhitespace` applies to a single-scalar character.
    private func isWhitespaceScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
            return true
        default:
            return scalar.properties.isWhitespace
        }
    }

    /// True when the scalar is a line break under the same rule as
    /// `Character.isNewline` applies to a single-scalar character.
    private func isNewlineScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    private func skipWhitespace(in text: String, index: inout String.Index) {
        let scalars = text.unicodeScalars
        while index < text.endIndex, isWhitespaceScalar(scalars[index]) {
            index = scalars.index(after: index)
        }
    }

    private func skipPropertyDeclarationWhitespace(in text: String, index: inout String.Index) throws {
        while index < text.endIndex, text[index].isWhitespace {
            if text[index].isNewline {
                throw USDError.invalidData("USDA property declaration cannot split type and name across lines.")
            }
            index = text.index(after: index)
        }
    }

    private func skipPropertyValueStartWhitespace(in text: String, index: inout String.Index) throws {
        while index < text.endIndex, text[index].isWhitespace {
            if text[index].isNewline {
                throw USDError.invalidData("USDA property value cannot start on a new line after '='.")
            }
            index = text.index(after: index)
        }
    }

    private func skipPropertyNameTrailingWhitespace(in text: String, index: inout String.Index) -> Bool {
        while index < text.endIndex, text[index].isWhitespace {
            if text[index].isNewline {
                return true
            }
            index = text.index(after: index)
        }
        guard index < text.endIndex else {
            return true
        }
        return text[index] == ";" || text[index] == "}" || text[index] == "#"
    }

    private func skipPrimDeclarationWhitespace(in text: String, index: inout String.Index) throws {
        while index < text.endIndex, text[index].isWhitespace {
            if text[index].isNewline {
                throw USDError.invalidData("USDA prim declaration cannot split specifier, type, and name across lines.")
            }
            index = text.index(after: index)
        }
    }

    private func skipLineComment(in text: String, index: inout String.Index) {
        let scalars = text.unicodeScalars
        while index < text.endIndex, !isNewlineScalar(scalars[index]) {
            index = scalars.index(after: index)
        }
    }

    /// Skips a USDA asset literal using the same delimiter rules as
    /// `parseAssetPath(startingAt:in:endIndex:)`.
    private func skipAssetPathLiteral(in text: String, index: inout String.Index) throws {
        let scalars = text.unicodeScalars
        let openRunLength = repeatedCharacterCount(at: index, character: "@", in: text)
        let delimiterLength = openRunLength >= 3 ? 3 : 1
        index = scalars.index(index, offsetBy: delimiterLength)
        if delimiterLength == 1 {
            while index < text.endIndex {
                if scalars[index] == "@" {
                    index = scalars.index(after: index)
                    return
                }
                index = scalars.index(after: index)
            }
            throw USDError.invalidData("USDA asset path is unterminated.")
        }
        while index < text.endIndex {
            if scalars[index] == "\\" {
                let escapeStart = scalars.index(after: index)
                if repeatedCharacterCount(at: escapeStart, character: "@", in: text) >= 3 {
                    index = scalars.index(escapeStart, offsetBy: 3)
                    continue
                }
                index = scalars.index(after: index)
                continue
            }
            if scalars[index] == "@" {
                let runLength = repeatedCharacterCount(at: index, character: "@", in: text)
                index = scalars.index(index, offsetBy: runLength)
                if runLength >= 3 {
                    return
                }
                continue
            }
            index = scalars.index(after: index)
        }
        throw USDError.invalidData("USDA asset path is unterminated.")
    }

    private func parseUpAxis(in text: String) throws -> USDUpAxis {
        guard let value = try parseOptionalString(named: "upAxis", in: text) else {
            return .y
        }
        guard let axis = USDUpAxis(rawValue: value) else {
            throw USDError.invalidData("Unsupported USDA upAxis \(value).")
        }
        return axis
    }

    private func parseOptionalOrientation(in text: String) throws -> USDOrientation? {
        guard let value = try parseOptionalString(named: "orientation", in: text) else {
            return nil
        }
        guard let orientation = USDOrientation(rawValue: value) else {
            throw USDError.invalidData("Unsupported USDA orientation \(value).")
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
            // An op listed in xformOpOrder may have no attribute spec in this layer:
            // the attribute can be authored in another layer and only become visible
            // after composition. Upstream UsdGeomXformable::GetOrderedXformOps warns
            // and skips such ops instead of failing, so we mirror that behavior here
            // rather than throwing on a single-layer read.
            guard try attributeNameRange(named: orderedOp.attributeName, in: text) != nil else {
                continue
            }
            let opTransform = try self.transform(forXformOp: orderedOp.attributeName, in: text)
            let effectiveTransform = orderedOp.isInverted ? try opTransform.inverted() : opTransform
            transform = try transform.concatenating(effectiveTransform)
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
            throw USDError.invalidData("USDA xform op \(opName) is malformed.")
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
            throw USDError.unsupportedFeature("USDA xform op \(operationType) is not supported yet.")
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
        guard let valueStart = try assignedValueStart(named: name, in: text) else {
            return nil
        }
        guard valueStart < text.endIndex else {
            throw USDError.invalidData("USDA \(name) is not a quoted string.")
        }
        if isNoneValue(at: valueStart, in: text) {
            return nil
        }
        guard text[valueStart] == "\"" || text[valueStart] == "'" else {
            throw USDError.invalidData("USDA \(name) is not a quoted string.")
        }
        return try parseQuotedString(startingAt: valueStart, in: text).value
    }

    private func parseOptionalDouble(named name: String, in text: String) throws -> Double? {
        guard let valueStart = try assignedValueStart(named: name, in: text) else {
            return nil
        }
        var valueEnd = valueStart
        while valueEnd < text.endIndex {
            let character = text[valueEnd]
            if character.isWhitespace
                || character == ","
                || character == ";"
                || character == ")"
                || character == "]"
                || character == "}" {
                break
            }
            valueEnd = text.index(after: valueEnd)
        }
        let match = String(text[valueStart..<valueEnd])
        guard let value = Double(match) else {
            throw USDError.invalidData("USDA \(name) is not a valid number.")
        }
        return value
    }

    private func assignedValueStart(named name: String, in text: String) throws -> String.Index? {
        guard let nameRange = try attributeNameRange(named: name, in: text) else {
            return nil
        }
        return try propertyAssignmentValueStart(afterPropertyName: nameRange.upperBound, in: text)
    }

    private func parseOptionalTokenArray(named name: String, in text: String) throws -> [String]? {
        guard let body = try optionalBracketArrayBody(named: name, in: text) else {
            return nil
        }
        // Scan the bracket array body for double-quoted tokens directly instead of
        // compiling an NSRegularExpression on every call.
        var tokens: [String] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard body[cursor] == "\"" else {
                cursor = body.index(after: cursor)
                continue
            }
            let contentStart = body.index(after: cursor)
            guard let closingQuote = body[contentStart...].firstIndex(of: "\"") else {
                throw USDError.invalidData("USDA \(name) contains an unterminated token string.")
            }
            tokens.append(String(body[contentStart..<closingQuote]))
            cursor = body.index(after: closingQuote)
        }
        return tokens
    }

    private func parseCompositionArcs(
        forField name: String,
        in text: String,
        sitePrimPath: String
    ) throws -> [USDCompositionArc] {
        try parseEffectiveAssetReferences(forField: name, in: text).map { reference in
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
    ) throws -> [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] {
        guard let body = try compositionFieldBody(named: name, in: text) else {
            return []
        }
        return try parseAssetReferences(in: body)
    }

    private func parseEffectiveAssetReferences(
        forField name: String,
        in text: String
    ) throws -> [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] {
        let edits = try parseAssetReferenceListEdits(forField: name, in: text)
        var references: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] = []
        for edit in edits {
            switch edit.operation {
            case .explicit:
                references = []
                appendUniqueAssetReferences(edit.references, to: &references)
            case .add, .append:
                appendUniqueAssetReferences(edit.references, to: &references)
            case .prepend:
                var prepended: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] = []
                appendUniqueAssetReferences(edit.references, to: &prepended)
                appendUniqueAssetReferences(references, to: &prepended)
                references = prepended
            case .delete:
                references.removeAll { reference in
                    edit.references.contains { deletedReference in
                        assetReference(reference, matches: deletedReference)
                    }
                }
            case .reorder:
                references = reorderedAssetReferences(references, using: edit.references)
            }
        }
        return references
    }

    private func parseAssetReferenceListEdits(
        forField name: String,
        in text: String
    ) throws -> [USDAAssetReferenceListEdit] {
        var edits: [USDAAssetReferenceListEdit] = []
        var cursor = text.startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
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
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }

            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel,
               let match = compositionListEditAssignment(at: cursor, fieldName: name, in: text) {
                var bodyEnd = match.fieldEnd
                let body = try compositionAssignmentBody(after: match.fieldEnd, named: name, in: text, endIndex: &bodyEnd)
                edits.append(USDAAssetReferenceListEdit(
                    operation: match.operation,
                    references: try parseAssetReferences(in: body)
                ))
                cursor = bodyEnd
                continue
            }

            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            }
            cursor = text.index(after: cursor)
        }
        return edits
    }

    private func compositionListEditAssignment(
        at index: String.Index,
        fieldName: String,
        in text: String
    ) -> (operation: USDAListEditOperation, fieldEnd: String.Index)? {
        for operation in USDAListEditOperation.qualifiedOperations {
            guard token(operation.rawValue, matchesAt: index, in: text) else {
                continue
            }
            var fieldCursor = text.index(index, offsetBy: operation.rawValue.count)
            skipWhitespace(in: text, index: &fieldCursor)
            guard token(fieldName, matchesAt: fieldCursor, in: text),
                  let fieldEnd = text.index(fieldCursor, offsetBy: fieldName.count, limitedBy: text.endIndex) else {
                continue
            }
            return (operation, fieldEnd)
        }
        guard token(fieldName, matchesAt: index, in: text),
              let fieldEnd = text.index(index, offsetBy: fieldName.count, limitedBy: text.endIndex) else {
            return nil
        }
        return (.explicit, fieldEnd)
    }

    private func compositionAssignmentBody(
        after fieldEnd: String.Index,
        named name: String,
        in text: String,
        endIndex: inout String.Index
    ) throws -> String {
        var cursor = fieldEnd
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "=" else {
            throw USDError.invalidData("USDA \(name) list-edit is missing an assignment.")
        }
        cursor = text.index(after: cursor)
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex else {
            endIndex = cursor
            return ""
        }
        if text[cursor] == "[" {
            let closeBracket = try matchingBracket(startingAt: cursor, in: text)
            endIndex = text.index(after: closeBracket)
            return String(text[text.index(after: cursor)..<closeBracket])
        }

        let valueStart = cursor
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel,
               character == "\n" || character == "\r" || character == ";" || character == "#" {
                break
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &cursor)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &cursor)
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            }
            cursor = text.index(after: cursor)
        }
        endIndex = cursor
        return String(text[valueStart..<cursor])
    }

    private func parseAssetReferences(
        in body: String
    ) throws -> [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] {
        try parseAssetReferenceValues(in: body).map {
            (assetPath: $0.assetPath, primPath: $0.primPath, layerOffset: $0.layerOffset)
        }
    }

    private func parseSdfReferences(in value: String) throws -> [SdfReference] {
        try parseAssetReferenceValues(in: listEditValueBody(value)).map { reference in
            SdfReference(
                assetPath: reference.assetPath,
                primPath: try reference.primPath.map { try SdfPath($0) },
                layerOffset: reference.layerOffset,
                customData: reference.customData
            )
        }
    }

    private func parseSdfPayloads(in value: String) throws -> [SdfPayload] {
        try parseAssetReferenceValues(in: listEditValueBody(value)).map { payload in
            SdfPayload(
                assetPath: payload.assetPath,
                primPath: try payload.primPath.map { try SdfPath($0) },
                layerOffset: payload.layerOffset
            )
        }
    }

    private func listEditValueBody(_ value: String) throws -> String {
        var cursor = value.startIndex
        skipWhitespace(in: value, index: &cursor)
        guard cursor < value.endIndex else {
            return ""
        }
        if isNoneValue(at: cursor, in: value) {
            return ""
        }
        guard value[cursor] == "[" else {
            return value
        }
        let closeBracket = try matchingBracket(startingAt: cursor, in: value)
        return String(value[value.index(after: cursor)..<closeBracket])
    }

    private func parseAssetReferenceValues(in body: String) throws -> [USDAAssetReferenceValue] {
        var references: [USDAAssetReferenceValue] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            if body[cursor] == "#" {
                skipLineComment(in: body, index: &cursor)
                continue
            }
            if body[cursor].isWhitespace || body[cursor] == "," {
                cursor = body.index(after: cursor)
                continue
            }
            if isNoneValue(at: cursor, in: body),
               let noneEnd = body.index(cursor, offsetBy: 4, limitedBy: body.endIndex) {
                cursor = noneEnd
                continue
            }
            if body[cursor] == "<" {
                let primPath = try parseOptionalPrimPath(in: body, index: &cursor)
                skipWhitespace(in: body, index: &cursor)
                let metadata = try parseOptionalAssetReferenceMetadata(in: body, index: &cursor)
                references.append(USDAAssetReferenceValue(
                    assetPath: "",
                    primPath: primPath,
                    layerOffset: metadata.layerOffset,
                    customData: metadata.customData
                ))
                continue
            }
            guard body[cursor] == "@" else {
                throw USDError.invalidData("USDA composition arc list contains unexpected content.")
            }
            let assetPath = try parseAssetPath(startingAt: cursor, in: body, endIndex: &cursor)
            skipWhitespace(in: body, index: &cursor)
            let primPath = try parseOptionalPrimPath(in: body, index: &cursor)
            skipWhitespace(in: body, index: &cursor)
            let metadata = try parseOptionalAssetReferenceMetadata(in: body, index: &cursor)
            references.append(USDAAssetReferenceValue(
                assetPath: assetPath,
                primPath: primPath,
                layerOffset: metadata.layerOffset,
                customData: metadata.customData
            ))
        }
        return references
    }

    private func appendUniqueAssetReferences(
        _ newReferences: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)],
        to references: inout [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)]
    ) {
        for reference in newReferences {
            guard !references.contains(where: { assetReference($0, matches: reference) }) else {
                continue
            }
            references.append(reference)
        }
    }

    private func reorderedAssetReferences(
        _ references: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)],
        using orderedReferences: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)]
    ) -> [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] {
        var reordered: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)] = []
        for orderedReference in orderedReferences {
            guard let reference = references.first(where: { assetReference($0, matches: orderedReference) }) else {
                continue
            }
            appendUniqueAssetReferences([reference], to: &reordered)
        }
        appendUniqueAssetReferences(references, to: &reordered)
        return reordered
    }

    private func assetReference(
        _ lhs: (assetPath: String, primPath: String?, layerOffset: SdfLayerOffset),
        matches rhs: (assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)
    ) -> Bool {
        lhs.assetPath == rhs.assetPath
            && lhs.primPath == rhs.primPath
            && lhs.layerOffset == rhs.layerOffset
    }

    /// Parses a USDA asset literal at `openDelimiter`.
    ///
    /// Single-delimiter literals (`@path@`) cannot contain `@`. Triple-delimiter
    /// literals (`@@@path@@@`) may contain runs of one or two `@` characters,
    /// escape a literal `@@@` as `\@@@`, and close on a run of three or more
    /// `@` characters whose final three act as the delimiter.
    private func parseAssetPath(
        startingAt openDelimiter: String.Index,
        in text: String,
        endIndex: inout String.Index
    ) throws -> String {
        let openRunLength = repeatedCharacterCount(at: openDelimiter, character: "@", in: text)
        let delimiterLength = openRunLength >= 3 ? 3 : 1
        var cursor = text.index(openDelimiter, offsetBy: delimiterLength)
        var assetPath = ""
        if delimiterLength == 1 {
            while cursor < text.endIndex {
                if text[cursor] == "@" {
                    endIndex = text.index(after: cursor)
                    guard !assetPath.isEmpty else {
                        throw USDError.invalidData("USDA asset path cannot be empty.")
                    }
                    return assetPath
                }
                assetPath.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            throw USDError.invalidData("USDA asset path is unterminated.")
        }
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "\\" {
                let escapeStart = text.index(after: cursor)
                if repeatedCharacterCount(at: escapeStart, character: "@", in: text) >= 3 {
                    assetPath.append("@@@")
                    cursor = text.index(escapeStart, offsetBy: 3)
                    continue
                }
                assetPath.append(character)
                cursor = text.index(after: cursor)
                continue
            }
            if character == "@" {
                let runLength = repeatedCharacterCount(at: cursor, character: "@", in: text)
                if runLength >= 3 {
                    if runLength > 3 {
                        assetPath.append(String(repeating: "@", count: runLength - 3))
                    }
                    endIndex = text.index(cursor, offsetBy: runLength)
                    guard !assetPath.isEmpty else {
                        throw USDError.invalidData("USDA asset path cannot be empty.")
                    }
                    return assetPath
                }
                assetPath.append(String(repeating: "@", count: runLength))
                cursor = text.index(cursor, offsetBy: runLength)
                continue
            }
            assetPath.append(character)
            cursor = text.index(after: cursor)
        }
        throw USDError.invalidData("USDA asset path is unterminated.")
    }

    private func parseOptionalPrimPath(in text: String, index: inout String.Index) throws -> String? {
        guard index < text.endIndex, text[index] == "<" else {
            return nil
        }
        guard let closeAngle = text[index...].firstIndex(of: ">") else {
            throw USDError.invalidData("USDA composition arc prim path is unterminated.")
        }
        let value = String(text[text.index(after: index)..<closeAngle])
        index = text.index(after: closeAngle)
        try validateCompositionPrimPath(value)
        return value.isEmpty ? nil : value
    }

    private func validateCompositionPrimPath(_ path: String) throws {
        guard !path.isEmpty else {
            return
        }
        try validateUSDPath(path, subject: "composition arc prim path")
    }

    private func validateUSDPath(_ path: String, subject: String) throws {
        guard !path.isEmpty else {
            throw USDError.invalidData("USDA \(subject) cannot be empty.")
        }
        let invalidCharacters: Set<Character> = ["\\", "?", "*", "\"", "'"]
        guard !path.contains(where: { invalidCharacters.contains($0) || $0.isWhitespace }) else {
            throw USDError.invalidData("USDA \(subject) contains invalid path characters.")
        }
        guard !path.contains("{"), !path.contains("}") else {
            throw USDError.invalidData("USDA \(subject) cannot contain variant selections.")
        }
    }

    private func parseOptionalLayerOffset(in text: String, index: inout String.Index) throws -> SdfLayerOffset {
        guard index < text.endIndex, text[index] == "(" else {
            return .identity
        }
        let closeParenthesis = try matchingParenthesis(startingAt: index, in: text)
        let body = String(text[text.index(after: index)..<closeParenthesis])
        index = text.index(after: closeParenthesis)
        return try parseLayerOffset(in: body)
    }

    private func parseOptionalAssetReferenceMetadata(
        in text: String,
        index: inout String.Index
    ) throws -> (layerOffset: SdfLayerOffset, customData: [String: SdfFieldValue]) {
        guard index < text.endIndex, text[index] == "(" else {
            return (.identity, [:])
        }
        let closeParenthesis = try matchingParenthesis(startingAt: index, in: text)
        let body = String(text[text.index(after: index)..<closeParenthesis])
        index = text.index(after: closeParenthesis)
        return (try parseLayerOffset(in: body), try parseReferenceCustomData(in: body))
    }

    private func parseLayerOffset(in text: String) throws -> SdfLayerOffset {
        let offset = try parseOptionalDouble(named: "offset", in: text) ?? 0
        let scale = try parseOptionalDouble(named: "scale", in: text) ?? 1
        guard offset.isFinite, scale.isFinite else {
            throw USDError.invalidData("USDA layer offset must contain finite values.")
        }
        return SdfLayerOffset(offset: offset, scale: scale)
    }

    private func parseReferenceCustomData(in text: String) throws -> [String: SdfFieldValue] {
        guard let nameRange = try attributeNameRange(named: "customData", in: text) else {
            return [:]
        }
        guard let valueStart = try propertyAssignmentValueStart(afterPropertyName: nameRange.upperBound, in: text),
              valueStart < text.endIndex,
              text[valueStart] == "{" else {
            throw USDError.invalidData("USDA reference customData must use a dictionary value.")
        }
        let closeBrace = try matchingBrace(startingAt: valueStart, in: text)
        return try parseSdfDictionaryEntries(in: String(text[text.index(after: valueStart)..<closeBrace]))
    }

    private func parseSdfDictionary(from authoredValue: String) throws -> [String: SdfFieldValue] {
        let value = trimmed(authoredValue)
        guard !value.isEmpty, value[value.startIndex] == "{" else {
            throw USDError.invalidData("USDA dictionary value must use braces.")
        }
        let closeBrace = try matchingBrace(startingAt: value.startIndex, in: value)
        let trailingText = trimmed(String(value[value.index(after: closeBrace)..<value.endIndex]))
        guard trailingText.isEmpty else {
            throw USDError.invalidData("USDA dictionary value contains trailing content.")
        }
        return try parseSdfDictionaryEntries(in: String(value[value.index(after: value.startIndex)..<closeBrace]))
    }

    private func parseStringDictionary(from authoredValue: String, fieldName: String) throws -> [String: SdfFieldValue] {
        let value = trimmed(authoredValue)
        guard !value.isEmpty, value[value.startIndex] == "{" else {
            throw USDError.invalidData("USDA \(fieldName) metadata must use a string dictionary value.")
        }
        let closeBrace = try matchingBrace(startingAt: value.startIndex, in: value)
        let trailingText = trimmed(String(value[value.index(after: closeBrace)..<value.endIndex]))
        guard trailingText.isEmpty else {
            throw USDError.invalidData("USDA \(fieldName) metadata contains trailing content.")
        }
        let body = String(value[value.index(after: value.startIndex)..<closeBrace])
        return try parseStringDictionaryEntries(in: body, fieldName: fieldName)
    }

    private func parseStringDictionaryEntries(in text: String, fieldName: String) throws -> [String: SdfFieldValue] {
        var cursor = text.startIndex
        var values: [String: SdfFieldValue] = [:]
        while cursor < text.endIndex {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex else {
                break
            }
            if text[cursor] == "," || text[cursor] == ";" {
                cursor = text.index(after: cursor)
                continue
            }
            let key = try parseStringDictionaryString(in: text, index: &cursor, fieldName: fieldName, role: "key")
            guard !key.isEmpty else {
                throw USDError.invalidData("USDA \(fieldName) metadata keys cannot be empty.")
            }
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex, text[cursor] == ":" else {
                throw USDError.invalidData("USDA \(fieldName) metadata entries must separate keys and values with ':'.")
            }
            cursor = text.index(after: cursor)
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            let value = try parseStringDictionaryString(in: text, index: &cursor, fieldName: fieldName, role: "value")
            values[key] = .string(value)
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            if cursor < text.endIndex {
                guard text[cursor] == "," || text[cursor] == ";" else {
                    throw USDError.invalidData("USDA \(fieldName) metadata entries must be separated by commas.")
                }
                cursor = text.index(after: cursor)
            }
        }
        return values
    }

    private func parseStringDictionaryString(
        in text: String,
        index: inout String.Index,
        fieldName: String,
        role: String
    ) throws -> String {
        guard index < text.endIndex,
              text[index] == "\"" || text[index] == "'" else {
            throw USDError.invalidData("USDA \(fieldName) metadata \(role) must be a quoted string.")
        }
        let parsed = try parseQuotedString(startingAt: index, in: text)
        index = parsed.endIndex
        return parsed.value
    }

    private func parseSdfDictionaryEntries(in text: String) throws -> [String: SdfFieldValue] {
        var cursor = text.startIndex
        var values: [String: SdfFieldValue] = [:]
        while cursor < text.endIndex {
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            while cursor < text.endIndex, text[cursor] == ";" {
                cursor = text.index(after: cursor)
                skipWhitespaceAndLineComments(in: text, index: &cursor)
            }
            guard cursor < text.endIndex else {
                break
            }
            let typeName = try parseDictionaryTypeName(in: text, index: &cursor)
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            let key = try parseDictionaryKey(in: text, index: &cursor)
            skipWhitespaceAndLineComments(in: text, index: &cursor)
            guard cursor < text.endIndex, text[cursor] == "=" else {
                throw USDError.invalidData("USDA dictionary entry is missing an assignment.")
            }
            cursor = text.index(after: cursor)
            skipWhitespace(in: text, index: &cursor)
            let valueStart = cursor
            let valueEnd = try statementEnd(startingAt: valueStart, in: text)
            let authoredValue = trimmed(String(text[valueStart..<valueEnd]))
            values[key] = try customDataFieldValue(typeName: typeName, authoredValue: authoredValue)
            cursor = valueEnd
            if cursor < text.endIndex, text[cursor] == ";" {
                cursor = text.index(after: cursor)
            }
        }
        return values
    }

    private func parseDictionaryTypeName(in text: String, index: inout String.Index) throws -> String {
        let typeStart = index
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character == "=" || character == ";" {
                break
            }
            index = text.index(after: index)
        }
        guard typeStart < index else {
            throw USDError.invalidData("USDA dictionary entry is missing a type name.")
        }
        return String(text[typeStart..<index])
    }

    private func parseDictionaryKey(in text: String, index: inout String.Index) throws -> String {
        guard index < text.endIndex else {
            throw USDError.invalidData("USDA dictionary entry is missing a key.")
        }
        if text[index] == "\"" || text[index] == "'" {
            let parsed = try parseQuotedString(startingAt: index, in: text)
            index = parsed.endIndex
            return parsed.value
        }
        let keyStart = index
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character == "=" || character == ";" {
                break
            }
            index = text.index(after: index)
        }
        guard keyStart < index else {
            throw USDError.invalidData("USDA dictionary entry is missing a key.")
        }
        return String(text[keyStart..<index])
    }

    private func customDataFieldValue(typeName: String, authoredValue: String) throws -> SdfFieldValue {
        switch typeName {
        case "bool":
            guard let value = boolValue(authoredValue) else {
                throw USDError.invalidData("USDA dictionary bool value is invalid.")
            }
            return .bool(value)
        case "bool[]":
            return .boolArray(try boolArrayValue(authoredValue))
        case "token":
            return .token(try stringLikeCustomDataValue(authoredValue))
        case "token[]":
            return .tokenArray(try stringArrayValue(authoredValue))
        case "string":
            return .string(try stringLikeCustomDataValue(authoredValue))
        case "string[]":
            return .stringVector(try stringArrayValue(authoredValue))
        case "asset":
            return .assetPath(try assetPathValue(authoredValue))
        case "dictionary":
            return .dictionary(try parseSdfDictionary(from: authoredValue))
        case "int":
            guard let value = Int(authoredValue) else {
                throw USDError.invalidData("USDA dictionary int value is invalid.")
            }
            return .int(value)
        case "int[]":
            return .intArray(try intArrayValue(authoredValue))
        case "double", "float":
            guard let value = Double(authoredValue), value.isFinite else {
                throw USDError.invalidData("USDA dictionary double value is invalid.")
            }
            return .double(value)
        case "double[]", "float[]":
            return .doubleArray(try doubleArrayValue(authoredValue))
        case "double2", "float2", "half2", "texCoord2d", "texCoord2f", "texCoord2h":
            return .point2(try point2Value(authoredValue))
        case "double2[]", "float2[]", "half2[]", "texCoord2d[]", "texCoord2f[]", "texCoord2h[]":
            return .point2Array(try point2ArrayValue(authoredValue))
        case "timecode":
            guard let value = Double(authoredValue), value.isFinite else {
                throw USDError.invalidData("USDA dictionary timecode value is invalid.")
            }
            return .timeCode(value)
        case "timecode[]":
            return .timeCodeArray(try doubleArrayValue(authoredValue))
        default:
            throw USDError.unsupportedFeature(
                "USDA dictionary type \(typeName) is not supported by swift-OpenUSD authoring yet."
            )
        }
    }

    private func assetPathValue(_ value: String) throws -> String {
        let value = trimmed(value)
        guard !value.isEmpty, value[value.startIndex] == "@" else {
            throw USDError.invalidData("USDA dictionary asset value is invalid.")
        }
        var endIndex = value.startIndex
        let assetPath = try parseAssetPath(startingAt: value.startIndex, in: value, endIndex: &endIndex)
        guard trimmed(String(value[endIndex..<value.endIndex])).isEmpty else {
            throw USDError.invalidData("USDA dictionary asset value contains trailing content.")
        }
        return assetPath
    }

    private func point2Value(_ value: String) throws -> USDPoint2D {
        let values = try parseNumericTupleBody(named: "dictionary double2", expectedCount: 2, in: tupleBody(value))
        return USDPoint2D(x: values[0], y: values[1])
    }

    private func point2ArrayValue(_ value: String) throws -> [USDPoint2D] {
        try customDataArrayTokens(value).map { try point2Value($0) }
    }

    private func tupleBody(_ value: String) throws -> String {
        let value = trimmed(value)
        guard !value.isEmpty, value[value.startIndex] == "(" else {
            throw USDError.invalidData("USDA dictionary tuple value is invalid.")
        }
        let closeParenthesis = try matchingParenthesis(startingAt: value.startIndex, in: value)
        guard trimmed(String(value[value.index(after: closeParenthesis)..<value.endIndex])).isEmpty else {
            throw USDError.invalidData("USDA dictionary tuple value contains trailing content.")
        }
        return String(value[value.index(after: value.startIndex)..<closeParenthesis])
    }

    private func boolValue(_ value: String) -> Bool? {
        switch value {
        case "true", "True":
            return true
        case "false", "False":
            return false
        default:
            return nil
        }
    }

    private func boolArrayValue(_ value: String) throws -> [Bool] {
        try customDataArrayTokens(value).map { token in
            guard let value = boolValue(token) else {
                throw USDError.invalidData("USDA dictionary bool array contains an invalid value.")
            }
            return value
        }
    }

    private func intArrayValue(_ value: String) throws -> [Int] {
        try customDataArrayTokens(value).map { token in
            guard let value = Int(token) else {
                throw USDError.invalidData("USDA dictionary int array contains an invalid value.")
            }
            return value
        }
    }

    private func doubleArrayValue(_ value: String) throws -> [Double] {
        try customDataArrayTokens(value).map { token in
            guard let value = Double(token), value.isFinite else {
                throw USDError.invalidData("USDA dictionary double array contains an invalid value.")
            }
            return value
        }
    }

    private func stringArrayValue(_ value: String) throws -> [String] {
        try customDataArrayTokens(value).map { try stringLikeCustomDataValue($0) }
    }

    private func customDataArrayTokens(_ value: String) throws -> [String] {
        var cursor = value.startIndex
        skipWhitespace(in: value, index: &cursor)
        guard cursor < value.endIndex, value[cursor] == "[" else {
            throw USDError.invalidData("USDA dictionary array must use brackets.")
        }
        let closeBracket = try matchingBracket(startingAt: cursor, in: value)
        let body = String(value[value.index(after: cursor)..<closeBracket])
        return try commaSeparatedTopLevelValues(in: body)
    }

    private func commaSeparatedTopLevelValues(in text: String) throws -> [String] {
        var values: [String] = []
        var currentValue = ""
        var cursor = text.startIndex
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" {
                // Line comments may appear between values and are not part of them.
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                let literalStart = cursor
                try skipQuotedString(in: text, index: &cursor)
                currentValue += text[literalStart..<cursor]
                continue
            }
            if character == "@" {
                let literalStart = cursor
                try skipAssetPathLiteral(in: text, index: &cursor)
                currentValue += text[literalStart..<cursor]
                continue
            }
            let isAtTopLevel = parenthesisDepth == 0 && bracketDepth == 0 && braceDepth == 0
            if isAtTopLevel, character == "," {
                values.append(trimmed(currentValue))
                currentValue = ""
                cursor = text.index(after: cursor)
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            }
            currentValue.append(character)
            cursor = text.index(after: cursor)
        }
        let finalValue = trimmed(currentValue)
        if !finalValue.isEmpty {
            values.append(finalValue)
        }
        return values
    }

    private func stringLikeCustomDataValue(_ value: String) throws -> String {
        let trimmedValue = trimmed(value)
        guard !trimmedValue.isEmpty else {
            return ""
        }
        guard trimmedValue[trimmedValue.startIndex] == "\"" || trimmedValue[trimmedValue.startIndex] == "'" else {
            return trimmedValue
        }
        return try parseQuotedString(startingAt: trimmedValue.startIndex, in: trimmedValue).value
    }

    private func compositionFieldBody(named name: String, in text: String) throws -> String? {
        guard let nameRange = try attributeNameRange(named: name, in: text),
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
        guard let nameRange = try attributeNameRange(named: attributeName, in: text) else {
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
        if let timeSamplesBody = try optionalTimeSamplesBody(named: name, in: text) {
            switch try parsePointTimeSamples(named: name, in: timeSamplesBody, options: options) {
            case .value(let sampledPoints):
                return sampledPoints
            case .blocked:
                throw USDError.missingRequiredField(name)
            case .unresolved:
                break
            }
        }
        let body = try bracketArrayBody(named: name, in: text)
        return try parsePointTuples(named: name, in: body)
    }

    private func parseOptionalPointArray(
        named name: String,
        in text: String,
        options: USDReadingOptions = .default
    ) throws -> [USDPoint3D]? {
        if let timeSamplesBody = try optionalTimeSamplesBody(named: name, in: text) {
            switch try parsePointTimeSamples(named: name, in: timeSamplesBody, options: options) {
            case .value(let sampledPoints):
                return sampledPoints
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
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
        guard let nameRange = try attributeNameRange(named: name, in: text) else {
            throw USDError.missingRequiredField(name)
        }
        guard let equalSign = text[nameRange.upperBound...].firstIndex(of: "=") else {
            throw USDError.invalidData("USDA \(name) is missing an assignment.")
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
            throw USDError.invalidData("USDA \(name) contains a non-finite number.")
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
        let values = try parseRequiredMatrixValues(named: name, in: text)
        return USDTransformMatrix4x4(values: values)
    }

    private func parseRequiredMatrixValues(named name: String, in text: String) throws -> [Double] {
        guard let nameRange = try attributeNameRange(named: name, in: text) else {
            throw USDError.missingRequiredField(name)
        }
        guard let equalSign = text[nameRange.upperBound...].firstIndex(of: "=") else {
            throw USDError.invalidData("USDA \(name) is missing an assignment.")
        }
        guard let openParenthesis = text[equalSign...].firstIndex(of: "(") else {
            throw USDError.invalidData("USDA \(name) is missing an opening parenthesis.")
        }
        let closeParenthesis = try matchingParenthesis(startingAt: openParenthesis, in: text)
        let body = String(text[text.index(after: openParenthesis)..<closeParenthesis])
        if body.contains("(") {
            let rows = try parseNumericTupleArray(named: name, expectedCount: 4, in: body)
            guard rows.count == 4 else {
                throw USDError.invalidData("USDA \(name) matrix contains \(rows.count) rows.")
            }
            return rows.flatMap { $0 }
        }
        return try parseNumericTupleBody(named: name, expectedCount: 16, in: body)
    }

    private func parseRequiredTuple(
        named name: String,
        expectedCount: Int,
        in text: String
    ) throws -> [Double] {
        guard let nameRange = try attributeNameRange(named: name, in: text) else {
            throw USDError.missingRequiredField(name)
        }
        guard let equalSign = text[nameRange.upperBound...].firstIndex(of: "=") else {
            throw USDError.invalidData("USDA \(name) is missing an assignment.")
        }
        guard let openParenthesis = text[equalSign...].firstIndex(of: "(") else {
            throw USDError.invalidData("USDA \(name) is missing an opening parenthesis.")
        }
        let closeParenthesis = try matchingParenthesis(startingAt: openParenthesis, in: text)
        let body = String(text[text.index(after: openParenthesis)..<closeParenthesis])
        return try parseNumericTupleBody(named: name, expectedCount: expectedCount, in: body)
    }

    private func parsePointTuples(named name: String, in body: String) throws -> [USDPoint3D] {
        let tuples = try parseNumericTupleArray(named: name, expectedCount: 3, in: body)
        return tuples.map { values in
            let x = values[0]
            let y = values[1]
            let z = values[2]
            return USDPoint3D(x: x, y: y, z: z)
        }
    }

    private func parsePoint2Tuples(named name: String, in body: String) throws -> [USDPoint2D] {
        let tuples = try parseNumericTupleArray(named: name, expectedCount: 2, in: body)
        return tuples.map { values in
            let x = values[0]
            let y = values[1]
            return USDPoint2D(x: x, y: y)
        }
    }

    private func parsePointTimeSamples(
        named name: String,
        in body: String,
        options: USDReadingOptions
    ) throws -> USDAPointTimeSampleResolution {
        let entries = try parseTimeSampleEntries(in: body)
        guard !entries.isEmpty else {
            throw USDError.invalidData("USDA \(name).timeSamples contains no samples.")
        }
        var samples: [(timeCode: Double, points: [USDPoint3D])] = []
        for entry in entries {
            guard entry.value != "None" else {
                if let timeCode = options.timeCode, entry.timeCode == timeCode {
                    return .blocked
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
            guard let points = samples.first?.points else {
                return .unresolved
            }
            return .value(points)
        }
        guard let points = interpolatedPointSample(
            samples,
            at: timeCode,
            interpolation: options.timeSampleInterpolation
        ) else {
            return .unresolved
        }
        return .value(points)
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
        var entries: [(timeCode: Double, value: String)] = []
        var seenTimeCodes: Set<Double> = []
        var cursor = body.startIndex
        while true {
            skipWhitespaceAndLineComments(in: body, index: &cursor)
            guard cursor < body.endIndex else {
                return entries
            }
            if body[cursor] == "," {
                cursor = body.index(after: cursor)
                continue
            }

            let timeStart = cursor
            while cursor < body.endIndex, isNumberLiteralCharacter(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard timeStart < cursor,
                  let timeCode = Double(body[timeStart..<cursor]),
                  timeCode.isFinite else {
                throw USDError.invalidData("USDA timeSamples entry is malformed.")
            }
            guard seenTimeCodes.insert(timeCode).inserted else {
                throw USDError.invalidData("USDA timeSamples contains duplicate timeCode values.")
            }

            skipWhitespaceAndLineComments(in: body, index: &cursor)
            guard cursor < body.endIndex, body[cursor] == ":" else {
                throw USDError.invalidData("USDA timeSamples entry is missing a colon.")
            }
            cursor = body.index(after: cursor)
            skipWhitespaceAndLineComments(in: body, index: &cursor)

            guard cursor < body.endIndex else {
                throw USDError.invalidData("USDA timeSamples entry is malformed.")
            }
            if isNoneValue(at: cursor, in: body),
               let noneEnd = body.index(cursor, offsetBy: 4, limitedBy: body.endIndex) {
                entries.append((timeCode: timeCode, value: "None"))
                cursor = noneEnd
                continue
            }

            guard cursor < body.endIndex, body[cursor] == "[" else {
                throw USDError.invalidData("USDA timeSamples entry is malformed.")
            }
            let closeBracket = try matchingBracket(startingAt: cursor, in: body)
            entries.append((timeCode: timeCode, value: String(body[cursor...closeBracket])))
            cursor = body.index(after: closeBracket)
        }
    }

    private func isNumberLiteralCharacter(_ character: Character) -> Bool {
        character.isNumber || character == "." || character == "+" || character == "-" || character == "e" || character == "E"
    }

    private func removingLineComments(from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            result.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return result
    }

    private func parseColorTuples(named name: String, in body: String) throws -> [USDColorRGB] {
        let tuples = try parseNumericTupleArray(named: name, expectedCount: 3, in: body)
        return tuples.map { values in
            let r = values[0]
            let g = values[1]
            let b = values[2]
            return USDColorRGB(r: r, g: g, b: b)
        }
    }

    private func parseNumericTupleArray(
        named name: String,
        expectedCount: Int,
        in body: String
    ) throws -> [[Double]] {
        let body = removingLineComments(from: body)
        var cursor = body.startIndex
        var contentEnd = body.endIndex
        skipWhitespace(in: body, index: &cursor)
        if cursor < body.endIndex, body[cursor] == "[" {
            let closeBracket = try matchingBracket(startingAt: cursor, in: body)
            var trailingIndex = body.index(after: closeBracket)
            skipWhitespace(in: body, index: &trailingIndex)
            guard trailingIndex == body.endIndex else {
                throw USDError.invalidData("USDA \(name) contains unexpected tuple array content.")
            }
            cursor = body.index(after: cursor)
            contentEnd = closeBracket
        }

        var tuples: [[Double]] = []
        while true {
            skipWhitespace(in: body, index: &cursor)
            guard cursor < contentEnd else {
                break
            }
            if body[cursor] == "," {
                guard !tuples.isEmpty else {
                    throw USDError.invalidData("USDA \(name) tuple array has an unexpected separator.")
                }
                cursor = body.index(after: cursor)
                skipWhitespace(in: body, index: &cursor)
                if cursor >= contentEnd {
                    break
                }
            }
            guard cursor < contentEnd, body[cursor] == "(" else {
                throw USDError.invalidData("USDA \(name) tuple array contains unexpected content.")
            }
            let closeParenthesis = try matchingParenthesis(startingAt: cursor, in: body)
            guard closeParenthesis <= contentEnd else {
                throw USDError.invalidData("USDA \(name) tuple is malformed.")
            }
            let tupleBody = String(body[body.index(after: cursor)..<closeParenthesis])
            tuples.append(try parseNumericTupleBody(named: name, expectedCount: expectedCount, in: tupleBody))
            cursor = body.index(after: closeParenthesis)
        }
        guard !tuples.isEmpty else {
            throw USDError.invalidData("USDA \(name) contains no tuples.")
        }
        return tuples
    }

    private func parseNumericTupleBody(
        named name: String,
        expectedCount: Int,
        in body: String
    ) throws -> [Double] {
        let body = removingLineComments(from: body)
        var values: [Double] = []
        var cursor = body.startIndex
        while true {
            skipWhitespace(in: body, index: &cursor)
            guard cursor < body.endIndex else {
                break
            }
            let valueStart = cursor
            while cursor < body.endIndex, isNumberLiteralCharacter(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard valueStart < cursor,
                  let value = Double(body[valueStart..<cursor]),
                  value.isFinite else {
                throw USDError.invalidData("USDA \(name) tuple contains a non-finite number.")
            }
            values.append(value)
            skipWhitespace(in: body, index: &cursor)
            guard cursor < body.endIndex else {
                break
            }
            guard body[cursor] == "," else {
                throw USDError.invalidData("USDA \(name) tuple contains unexpected content.")
            }
            cursor = body.index(after: cursor)
            skipWhitespace(in: body, index: &cursor)
            guard cursor < body.endIndex else {
                throw USDError.invalidData("USDA \(name) tuple has a trailing separator.")
            }
        }
        guard values.count == expectedCount else {
            throw USDError.invalidData("USDA \(name) tuple contains \(values.count) values.")
        }
        return values
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
        let body = removingLineComments(from: body)
        let tokens = body.split { character in
            character == "," || character.isWhitespace || character.isNewline
        }
        guard !tokens.isEmpty else {
            throw USDError.invalidData("USDA \(name) is empty.")
        }
        return try tokens.map { token in
            guard let value = Int(token) else {
                throw USDError.invalidData("USDA \(name) contains a non-integer value.")
            }
            return value
        }
    }

    private func parseDoubleTokens(named name: String, in body: String) throws -> [Double] {
        let body = removingLineComments(from: body)
        let tokens = body.split { character in
            character == "," || character.isWhitespace || character.isNewline
        }
        guard !tokens.isEmpty else {
            throw USDError.invalidData("USDA \(name) is empty.")
        }
        return try tokens.map { token in
            guard let value = Double(token), value.isFinite else {
                throw USDError.invalidData("USDA \(name) contains a non-finite number.")
            }
            return value
        }
    }

    private func bracketArrayBody(named name: String, in text: String) throws -> String {
        guard let nameRange = try attributeNameRange(named: name, in: text) else {
            throw USDError.missingRequiredField(name)
        }
        guard let body = try assignedBracketArrayBody(after: nameRange.upperBound, named: name, in: text) else {
            throw USDError.missingRequiredField(name)
        }
        return body
    }

    private func optionalBracketArrayBody(named name: String, in text: String) throws -> String? {
        guard let nameRange = try attributeNameRange(named: name, in: text) else {
            return nil
        }
        return try assignedBracketArrayBody(after: nameRange.upperBound, named: name, in: text)
    }

    private func optionalTimeSamplesBody(named name: String, in text: String) throws -> String? {
        guard let nameRange = try attributeNameRange(named: "\(name).timeSamples", in: text) else {
            return nil
        }
        guard let openBrace = text[nameRange.upperBound...].firstIndex(of: "{") else {
            throw USDError.invalidData("USDA \(name).timeSamples is missing an opening brace.")
        }
        let closeBrace = try matchingBrace(startingAt: openBrace, in: text)
        return String(text[text.index(after: openBrace)..<closeBrace])
    }

    private func bracketArrayBody(after index: String.Index, named name: String, in text: String) throws -> String {
        guard index < text.endIndex, text[index] == "[" else {
            throw USDError.invalidData("USDA \(name) is missing an opening bracket.")
        }
        let closeBracket = try matchingBracket(startingAt: index, in: text)
        return String(text[text.index(after: index)..<closeBracket])
    }

    private func assignedBracketArrayBody(
        after index: String.Index,
        named name: String,
        in text: String
    ) throws -> String? {
        guard let valueStart = try propertyAssignmentValueStart(afterPropertyName: index, in: text) else {
            return nil
        }
        guard valueStart < text.endIndex else {
            throw USDError.invalidData("USDA \(name) is missing a value.")
        }
        if isNoneValue(at: valueStart, in: text) {
            return nil
        }
        return try bracketArrayBody(after: valueStart, named: name, in: text)
    }

    private func attributeNameRange(named name: String, in text: String) throws -> Range<String.Index>? {
        let scalars = text.unicodeScalars
        var index = text.startIndex
        var braceDepth = 0
        var bracketDepth = 0
        var parenthesisDepth = 0
        while index < text.endIndex {
            let character = scalars[index]
            if character == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &index)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &index)
                continue
            }
            let isAtTopLevel = braceDepth == 0 && bracketDepth == 0 && parenthesisDepth == 0
            guard isAtTopLevel,
                  matchesASCIIKeyword(name, at: index, in: scalars),
                  let nameEnd = scalars.index(index, offsetBy: name.count, limitedBy: scalars.endIndex) else {
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
                }
                index = scalars.index(after: index)
                continue
            }
            if hasValidAttributeLeadingBoundary(at: index, in: text),
               hasValidAttributeTrailingBoundary(at: nameEnd, in: text) {
                return index..<nameEnd
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    private func hasValidAttributeLeadingBoundary(at index: String.Index, in text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard index > scalars.startIndex else {
            return true
        }
        let previous = scalars[scalars.index(before: index)]
        return isWhitespaceScalar(previous) || previous == "]" || previous == "(" || previous == ","
    }

    private func hasValidAttributeTrailingBoundary(at index: String.Index, in text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard index < scalars.endIndex else {
            return true
        }
        let next = scalars[index]
        return isWhitespaceScalar(next)
            || next == "="
            || next == "["
            || next == "("
            || next == ","
            || next == ")"
            || next == ";"
    }

    private func isNoneValue(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex,
              text[index...].hasPrefix("None"),
              let valueEnd = text.index(index, offsetBy: 4, limitedBy: text.endIndex) else {
            return false
        }
        return hasValidAttributeTrailingBoundary(at: valueEnd, in: text)
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
        open: Unicode.Scalar,
        close: Unicode.Scalar,
        in text: String
    ) throws -> String.Index {
        let scalars = text.unicodeScalars
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            let character = scalars[index]
            if character == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            if character == "\"" || character == "'" {
                try skipQuotedString(in: text, index: &index)
                continue
            }
            if character == "@" {
                try skipAssetPathLiteral(in: text, index: &index)
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
            index = scalars.index(after: index)
        }
        throw USDError.invalidData("USDA delimiter is unterminated.")
    }

    private func skipQuotedString(in text: String, index: inout String.Index) throws {
        let scalars = text.unicodeScalars
        let quote = scalars[index]
        let delimiterLength = repeatedCharacterCount(at: index, character: quote, in: text) >= 3 ? 3 : 1
        index = scalars.index(index, offsetBy: delimiterLength)
        while index < text.endIndex {
            if scalars[index] == "\\" {
                index = scalars.index(after: index)
                if index < text.endIndex {
                    index = scalars.index(after: index)
                }
                continue
            }
            if repeatedCharacterCount(at: index, character: quote, in: text) >= delimiterLength {
                index = scalars.index(index, offsetBy: delimiterLength)
                return
            }
            index = scalars.index(after: index)
        }
        throw USDError.invalidData("USDA string is unterminated.")
    }

    private func repeatedCharacterCount(at index: String.Index, character: Unicode.Scalar, in text: String) -> Int {
        let scalars = text.unicodeScalars
        var cursor = index
        var count = 0
        while cursor < text.endIndex, scalars[cursor] == character {
            count += 1
            cursor = scalars.index(after: cursor)
        }
        return count
    }

}

private enum USDADirectDeclarationKind {
    case prim
    case variantSet
}

private struct USDAPrim {
    var specifier: SdfSpecifier
    var typeName: String?
    var name: String?
    var metadataBody: String
    var body: String
    var fullRange: Range<String.Index>
}

private struct USDAAssetReferenceListEdit {
    var operation: USDAListEditOperation
    var references: [(assetPath: String, primPath: String?, layerOffset: SdfLayerOffset)]
}

private struct USDAAssetReferenceValue {
    var assetPath: String
    var primPath: String?
    var layerOffset: SdfLayerOffset
    var customData: [String: SdfFieldValue]
}

private struct USDAVariantSet {
    var name: String
    var body: String
    var fullRange: Range<String.Index>
}

private struct USDAVariantBodySpecs {
    var isFullyMaterialized: Bool
    var propertySpecs: [USDLayerSpec] = []
    var propertyOrderOperation: SdfListOperation<String>?
    var variantSetSpecs: [USDLayerSpec] = []
    var childPrimSpecs: [USDLayerSpec] = []
}

private enum USDAListEditOperation: String {
    case explicit
    case add
    case prepend
    case append
    case delete
    case reorder

    static let qualifiedOperations: [USDAListEditOperation] = [
        .add,
        .prepend,
        .append,
        .delete,
        .reorder,
    ]
}

private struct USDAPropertySpecDeclaration {
    var path: String
    var specType: SdfSpecType
    var typeName: String?
    var fieldNames: Set<String>
    var fields: [String: USDLayerFieldValue]
    var childSpecs: [USDLayerSpec]
}

private struct USDAMetadataFields {
    var fieldNames: [String] = []
    var fields: [String: USDLayerFieldValue] = [:]
}

private enum USDAPropertyValueField {
    case connectionPaths
    case defaultValue
    case timeSamples
}

private struct USDALocalTransform {
    var matrix: USDTransformMatrix4x4
    var resetsParentStack: Bool
}

private enum USDAPointTimeSampleResolution {
    case value([USDPoint3D])
    case blocked
    case unresolved
}
