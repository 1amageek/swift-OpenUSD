import Foundation

public struct SdfPath: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable, Hashable {
        case pseudoRoot
        case prim
        case property
        case variantSet
        case variantSelection
        case propertyTarget
    }

    public static let absoluteRoot = SdfPath(unchecked: "/")

    public let rawValue: String

    public init(_ rawValue: String) throws {
        try Self.validate(rawValue)
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    /// The kind of the final path element. A path such as `/Root{v=x}/Child`
    /// is a prim path because its final element is a prim, regardless of
    /// variant selections appearing earlier in the path.
    public var kind: Kind {
        if rawValue == "/" {
            return .pseudoRoot
        }
        if Self.propertyTargetRange(in: rawValue) != nil {
            return .propertyTarget
        }
        if Self.propertySeparator(in: rawValue) != nil {
            return .property
        }
        if let variant = Self.finalVariantBody(in: rawValue) {
            return variant.contains("=") ? .variantSelection : .variantSet
        }
        return .prim
    }

    public var isPseudoRoot: Bool {
        kind == .pseudoRoot
    }

    public var isAbsolute: Bool {
        rawValue.hasPrefix("/")
    }

    public var isRelative: Bool {
        !isAbsolute
    }

    public var isPrimPath: Bool {
        kind == .prim
    }

    public var isPropertyPath: Bool {
        kind == .property
    }

    public var isPropertyTargetPath: Bool {
        kind == .propertyTarget
    }

    public var containsVariantSelection: Bool {
        rawValue.contains("{") && rawValue.contains("=")
    }

    public var name: String {
        switch kind {
        case .pseudoRoot:
            return ""
        case .property:
            return propertyName ?? ""
        case .propertyTarget:
            return targetPath?.name ?? ""
        case .variantSet, .variantSelection:
            return Self.finalPrimComponent(in: rawValue).map(Self.primNameWithoutVariant) ?? ""
        case .prim:
            return Self.finalPrimComponent(in: rawValue) ?? ""
        }
    }

    public var parentPath: SdfPath? {
        switch kind {
        case .pseudoRoot:
            return nil
        case .propertyTarget:
            return propertyPath
        case .property:
            return primPath
        case .variantSet, .variantSelection:
            guard let openBrace = rawValue.lastIndex(of: "{") else {
                return nil
            }
            return SdfPath(unchecked: String(rawValue[..<openBrace]))
        case .prim:
            guard isAbsolute else {
                guard let lastSlash = rawValue.lastIndex(of: "/") else {
                    return nil
                }
                return SdfPath(unchecked: String(rawValue[..<lastSlash]))
            }
            guard let lastSlash = rawValue.lastIndex(of: "/"), lastSlash != rawValue.startIndex else {
                return .absoluteRoot
            }
            return SdfPath(unchecked: String(rawValue[..<lastSlash]))
        }
    }

    public var primPath: SdfPath? {
        switch kind {
        case .pseudoRoot:
            return .absoluteRoot
        case .prim, .variantSelection:
            return self
        case .property:
            guard let separator = Self.propertySeparator(in: rawValue) else {
                return nil
            }
            return SdfPath(unchecked: String(rawValue[..<separator]))
        case .propertyTarget:
            return propertyPath?.primPath
        case .variantSet:
            return parentPath
        }
    }

    public var propertyPath: SdfPath? {
        switch kind {
        case .property:
            return self
        case .propertyTarget:
            guard let targetRange = Self.propertyTargetRange(in: rawValue) else {
                return nil
            }
            return SdfPath(unchecked: String(rawValue[..<targetRange.lowerBound]))
        case .pseudoRoot, .prim, .variantSet, .variantSelection:
            return nil
        }
    }

    public var propertyName: String? {
        guard kind == .property,
              let separator = Self.propertySeparator(in: rawValue) else {
            return nil
        }
        return String(rawValue[rawValue.index(after: separator)...])
    }

    public var targetPath: SdfPath? {
        guard kind == .propertyTarget,
              let targetRange = Self.propertyTargetRange(in: rawValue) else {
            return nil
        }
        let targetStart = rawValue.index(after: targetRange.lowerBound)
        return SdfPath(unchecked: String(rawValue[targetStart..<targetRange.upperBound]))
    }

    /// For a variant selection path such as `/Root{v=x}`, returns the
    /// corresponding variant set path `/Root{v}`. Returns nil for paths whose
    /// final element is not a variant selection.
    public var variantSetPath: SdfPath? {
        guard kind == .variantSelection,
              let openBrace = rawValue.lastIndex(of: "{"),
              let equals = rawValue[openBrace...].firstIndex(of: "=") else {
            return nil
        }
        let setName = rawValue[rawValue.index(after: openBrace)..<equals]
        return SdfPath(unchecked: "\(rawValue[..<openBrace]){\(setName)}")
    }

    public func appendingChild(_ name: String) throws -> SdfPath {
        try Self.validateIdentifier(name, label: "prim child name")
        guard kind == .pseudoRoot || kind == .prim || kind == .variantSelection else {
            throw USDError.invalidData("SdfPath child prims can only be appended to prim paths.")
        }
        return try SdfPath(rawValue == "/" ? "/\(name)" : "\(rawValue)/\(name)")
    }

    public func appendingProperty(_ name: String) throws -> SdfPath {
        try Self.validatePropertyName(name)
        guard kind == .prim || kind == .variantSelection else {
            throw USDError.invalidData("SdfPath properties can only be appended to prim paths.")
        }
        return try SdfPath("\(rawValue).\(name)")
    }

    public func appendingVariantSelection(_ set: String, _ selection: String) throws -> SdfPath {
        try Self.validateIdentifier(set, label: "variant set name")
        guard kind == .prim || kind == .variantSelection else {
            throw USDError.invalidData("SdfPath variant selections can only be appended to prim paths.")
        }
        return try SdfPath("\(rawValue){\(set)=\(selection)}")
    }

    public func appendingTarget(_ target: SdfPath) throws -> SdfPath {
        guard kind == .property else {
            throw USDError.invalidData("SdfPath targets can only be appended to property paths.")
        }
        return try SdfPath("\(rawValue)[\(target.rawValue)]")
    }

    /// Returns true when this path is `prefix` itself or is contained inside
    /// the namespace rooted at `prefix`. The check is namespace-aware:
    /// `/Foo` is not a prefix of `/FooBar`, but it is a prefix of `/Foo/Bar`,
    /// `/Foo.attr`, and `/Foo{v=x}`.
    public func hasPrefix(_ prefix: SdfPath) -> Bool {
        if rawValue == prefix.rawValue {
            return true
        }
        if prefix.isPseudoRoot {
            return isAbsolute
        }
        guard rawValue.hasPrefix(prefix.rawValue) else {
            return false
        }
        let boundary = rawValue[rawValue.index(rawValue.startIndex, offsetBy: prefix.rawValue.count)]
        return boundary == "/" || boundary == "." || boundary == "{" || boundary == "["
    }

    /// Returns the path obtained by substituting `newPrefix` for `oldPrefix`.
    /// Returns nil when this path does not have `oldPrefix` as a namespace
    /// prefix. Throws when the substituted path is not a valid SdfPath.
    public func replacingPrefix(_ oldPrefix: SdfPath, with newPrefix: SdfPath) throws -> SdfPath? {
        guard hasPrefix(oldPrefix) else {
            return nil
        }
        if rawValue == oldPrefix.rawValue {
            return newPrefix
        }
        let remainderStart = rawValue.index(rawValue.startIndex, offsetBy: oldPrefix.rawValue.count)
        let remainder = String(rawValue[remainderStart...])
        if newPrefix.isPseudoRoot {
            return try SdfPath(oldPrefix.isPseudoRoot ? "/\(remainder)" : remainder)
        }
        return try SdfPath(oldPrefix.isPseudoRoot ? "\(newPrefix.rawValue)/\(remainder)" : "\(newPrefix.rawValue)\(remainder)")
    }

    public static func < (lhs: SdfPath, rhs: SdfPath) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func validate(_ value: String) throws {
        guard !value.isEmpty else {
            throw USDError.invalidData("SdfPath must not be empty.")
        }
        if value == "/" {
            return
        }
        if let targetRange = propertyTargetRange(in: value) {
            let propertyPath = String(value[..<targetRange.lowerBound])
            let targetStart = value.index(after: targetRange.lowerBound)
            let targetPath = String(value[targetStart..<targetRange.upperBound])
            guard !propertyPath.isEmpty, !targetPath.isEmpty else {
                throw USDError.invalidData("SdfPath property target must include a property and target path.")
            }
            try validate(propertyPath)
            guard propertySeparator(in: propertyPath) != nil else {
                throw USDError.invalidData("SdfPath property target parent must be a property path.")
            }
            try validate(targetPath)
            guard propertyTargetRange(in: targetPath) == nil else {
                throw USDError.invalidData("SdfPath property targets must not be nested.")
            }
            return
        }
        guard !value.contains("["), !value.contains("]") else {
            throw USDError.invalidData("SdfPath target brackets are only valid around property targets.")
        }
        if let separator = propertySeparator(in: value) {
            let primText = String(value[..<separator])
            let propertyText = String(value[value.index(after: separator)...])
            try validatePrimPathText(primText, allowFinalVariantSet: false)
            try validatePropertyName(propertyText)
        } else {
            try validatePrimPathText(value, allowFinalVariantSet: true)
        }
    }

    private static func validatePrimPathText(_ value: String, allowFinalVariantSet: Bool) throws {
        guard value != "/" else {
            return
        }
        guard !value.hasSuffix("/") else {
            throw USDError.invalidData("SdfPath prim path must not end with a slash.")
        }
        let componentText = value.hasPrefix("/") ? value.dropFirst() : value[...]
        let components = componentText.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: \.isEmpty) else {
            throw USDError.invalidData("SdfPath prim path must not contain empty components.")
        }
        for (index, component) in components.enumerated() {
            if component == "." || component == ".." {
                continue
            }
            try validatePrimComponent(
                component,
                allowVariantSetWithoutSelection: allowFinalVariantSet && index == components.index(before: components.endIndex)
            )
        }
    }

    private static func validatePrimComponent(
        _ value: String,
        allowVariantSetWithoutSelection: Bool
    ) throws {
        guard !value.contains("."), !value.contains("["), !value.contains("]") else {
            throw USDError.invalidData("SdfPath prim component contains property syntax.")
        }
        guard let openBrace = value.firstIndex(of: "{") else {
            try validateIdentifier(value, label: "prim component")
            return
        }
        let primName = String(value[..<openBrace])
        try validateIdentifier(primName, label: "prim component")
        var cursor = openBrace
        var variantIndex = 0
        while cursor < value.endIndex {
            guard value[cursor] == "{" else {
                throw USDError.invalidData("SdfPath variant syntax is malformed.")
            }
            let bodyStart = value.index(after: cursor)
            guard let closeBrace = value[bodyStart...].firstIndex(of: "}") else {
                throw USDError.invalidData("SdfPath variant syntax is malformed.")
            }
            let body = String(value[bodyStart..<closeBrace])
            guard !body.isEmpty,
                  !body.contains("{"),
                  !body.contains("}") else {
                throw USDError.invalidData("SdfPath variant body must not be empty.")
            }
            let next = value.index(after: closeBrace)
            let isFinalVariant = next == value.endIndex
            try validateVariantBody(
                body,
                allowVariantSetWithoutSelection: allowVariantSetWithoutSelection && isFinalVariant
            )
            variantIndex += 1
            cursor = next
        }
        guard variantIndex > 0 else {
            throw USDError.invalidData("SdfPath variant syntax is malformed.")
        }
    }

    private static func validateVariantBody(
        _ body: String,
        allowVariantSetWithoutSelection: Bool
    ) throws {
        if let equals = body.firstIndex(of: "=") {
            let setName = String(body[..<equals])
            let selectionName = String(body[body.index(after: equals)...])
            try validateIdentifier(setName, label: "variant set name")
            guard !selectionName.isEmpty,
                  !selectionName.contains("/"),
                  !selectionName.contains("{"),
                  !selectionName.contains("}"),
                  !selectionName.contains(".") else {
                throw USDError.invalidData("SdfPath variant selection name is invalid.")
            }
        } else {
            guard allowVariantSetWithoutSelection else {
                throw USDError.invalidData("SdfPath variant set paths are only valid as spec paths.")
            }
            try validateIdentifier(body, label: "variant set name")
        }
    }

    private static func validatePropertyName(_ value: String) throws {
        guard !value.isEmpty else {
            throw USDError.invalidData("SdfPath property name must not be empty.")
        }
        guard !value.contains("."), !value.contains("["), !value.contains("]") else {
            throw USDError.invalidData("SdfPath property name contains path separators.")
        }
        for component in value.split(separator: ":", omittingEmptySubsequences: false) {
            try validateIdentifier(String(component), label: "property name component")
        }
    }

    private static func validateIdentifier(_ value: String, label: String) throws {
        guard let firstScalar = value.unicodeScalars.first else {
            throw USDError.invalidData("SdfPath \(label) must not be empty.")
        }
        guard firstScalar.value == 0x5f || firstScalar.properties.isXIDStart else {
            throw USDError.invalidData("SdfPath \(label) \(value) is not a valid identifier.")
        }
        for scalar in value.unicodeScalars.dropFirst() {
            guard scalar.value == 0x5f || scalar.properties.isXIDContinue else {
                throw USDError.invalidData("SdfPath \(label) \(value) is not a valid identifier.")
            }
        }
    }

    private static func propertySeparator(in value: String) -> String.Index? {
        var cursor = value.startIndex
        var braceDepth = 0
        var bracketDepth = 0
        while cursor < value.endIndex {
            let character = value[cursor]
            if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == ".",
                      braceDepth == 0,
                      bracketDepth == 0,
                      !isRelativeDotComponent(in: value, at: cursor) {
                return cursor
            }
            cursor = value.index(after: cursor)
        }
        return nil
    }

    private static func isRelativeDotComponent(in value: String, at index: String.Index) -> Bool {
        let componentStart = value[..<index].lastIndex(of: "/").map { value.index(after: $0) } ?? value.startIndex
        let componentEnd = value[index...].firstIndex(of: "/") ?? value.endIndex
        let component = value[componentStart..<componentEnd]
        return component == "." || component == ".."
    }

    private static func propertyTargetRange(in value: String) -> Range<String.Index>? {
        var cursor = value.startIndex
        var braceDepth = 0
        var openBracket: String.Index?
        while cursor < value.endIndex {
            let character = value[cursor]
            if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                braceDepth = max(0, braceDepth - 1)
            } else if character == "[", braceDepth == 0 {
                guard openBracket == nil else {
                    return nil
                }
                openBracket = cursor
            } else if character == "]", braceDepth == 0 {
                guard let openBracket else {
                    return nil
                }
                let next = value.index(after: cursor)
                guard next == value.endIndex else {
                    return nil
                }
                return openBracket..<cursor
            }
            cursor = value.index(after: cursor)
        }
        return nil
    }

    private static func finalPrimComponent(in value: String) -> String? {
        let primText: String
        if let separator = propertySeparator(in: value) {
            primText = String(value[..<separator])
        } else {
            primText = value
        }
        return primText.split(separator: "/").last.map(String.init)
    }

    private static func primNameWithoutVariant(_ value: String) -> String {
        guard let openBrace = value.firstIndex(of: "{") else {
            return value
        }
        return String(value[..<openBrace])
    }

    private static func finalVariantBody(in value: String) -> String? {
        guard let component = finalPrimComponent(in: value),
              let openBrace = component.lastIndex(of: "{"),
              component.last == "}" else {
            return nil
        }
        let start = component.index(after: openBrace)
        let end = component.index(before: component.endIndex)
        return String(component[start..<end])
    }
}
