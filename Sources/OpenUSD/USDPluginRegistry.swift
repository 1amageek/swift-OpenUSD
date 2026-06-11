import Foundation

public struct USDPluginRegistry: Sendable, Equatable {
    public private(set) var plugins: [USDPlugin]

    public init(plugins: [USDPlugin] = []) {
        self.plugins = plugins
    }

    @discardableResult
    public mutating func registerPlugInfo(from data: Data) throws -> [USDPlugin] {
        let object = try Self.plugInfoObject(from: data)
        guard object["Includes"] == nil else {
            throw USDError.unsupportedFeature(
                "plugInfo Includes require file resolution; use registerPlugInfo(at:) instead."
            )
        }
        return try registerPlugins(from: object)
    }

    @discardableResult
    public mutating func registerPlugInfo(at url: URL) throws -> [USDPlugin] {
        var visited: Set<String> = []
        return try registerPlugInfo(at: url, visited: &visited)
    }

    @discardableResult
    public mutating func registerPlugInfo(at path: String) throws -> [USDPlugin] {
        try registerPlugInfo(at: URL(fileURLWithPath: path))
    }

    public func plugin(named name: String) -> USDPlugin? {
        plugins.first { $0.name == name }
    }

    public func pluginsDeclaring(typeName: String) -> [USDPlugin] {
        plugins.filter { plugin in
            plugin.declaredTypeNames.contains(typeName)
        }
    }

    public var declaredTypeNames: [String] {
        Array(Set(plugins.flatMap(\.declaredTypeNames))).sorted()
    }

    private mutating func registerPlugInfo(at url: URL, visited: inout Set<String>) throws -> [USDPlugin] {
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(fileURL.path).inserted else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let object = try Self.plugInfoObject(from: data)
        var registered: [USDPlugin] = []
        for includeURL in try Self.includeURLs(from: object, baseURL: fileURL.deletingLastPathComponent()) {
            registered.append(contentsOf: try registerPlugInfo(at: includeURL, visited: &visited))
        }
        registered.append(contentsOf: try registerPlugins(from: object, baseURL: fileURL.deletingLastPathComponent()))
        return registered
    }

    private mutating func registerPlugins(
        from object: [String: USDPluginMetadataValue],
        baseURL: URL? = nil
    ) throws -> [USDPlugin] {
        let pluginObjects = try Self.pluginObjects(from: object)
        let registered = try pluginObjects.map { try Self.plugin(from: $0, baseURL: baseURL) }
        plugins.append(contentsOf: registered)
        return registered
    }

    private static func plugInfoObject(from data: Data) throws -> [String: USDPluginMetadataValue] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw USDError.invalidData("plugInfo data is not UTF-8.")
        }
        let stripped = stripHashComments(from: text)
        guard let jsonData = stripped.data(using: .utf8) else {
            throw USDError.invalidData("plugInfo JSON is not UTF-8.")
        }
        let object = try JSONSerialization.jsonObject(with: jsonData)
        guard let dictionary = object as? [String: Any] else {
            throw USDError.invalidData("plugInfo root must be a JSON object.")
        }
        guard case .dictionary(let value) = try metadataValue(from: dictionary) else {
            throw USDError.invalidData("plugInfo root must be a JSON object.")
        }
        return value
    }

    private static func pluginObjects(from object: [String: USDPluginMetadataValue]) throws -> [[String: USDPluginMetadataValue]] {
        if let value = object["Plugins"] {
            guard case .array(let plugins) = value else {
                throw USDError.invalidData("plugInfo Plugins must be an array.")
            }
            return try plugins.map { value in
                guard let dictionary = value.dictionaryValue else {
                    throw USDError.invalidData("plugInfo Plugins entries must be objects.")
                }
                return dictionary
            }
        }
        guard object["Includes"] == nil else {
            return []
        }
        return [object]
    }

    private static func includeURLs(
        from object: [String: USDPluginMetadataValue],
        baseURL: URL
    ) throws -> [URL] {
        guard let value = object["Includes"] else {
            return []
        }
        guard case .array(let includes) = value else {
            throw USDError.invalidData("plugInfo Includes must be an array.")
        }
        var urls: [URL] = []
        for include in includes {
            guard let includePath = include.stringValue, !includePath.isEmpty else {
                throw USDError.invalidData("plugInfo Includes entries must be non-empty strings.")
            }
            urls.append(contentsOf: try resolvedIncludeURLs(for: includePath, baseURL: baseURL))
        }
        return urls
    }

    private static func resolvedIncludeURLs(for includePath: String, baseURL: URL) throws -> [URL] {
        let normalizedPath = includePath.hasSuffix("/") ? "\(includePath)plugInfo.json" : includePath
        let absolutePath = absolutePath(for: normalizedPath, baseURL: baseURL)
        if normalizedPath.contains("*") {
            return try globbedIncludeURLs(for: absolutePath)
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory) else {
            throw USDError.invalidData("plugInfo include \(includePath) does not exist.")
        }
        let url = URL(fileURLWithPath: absolutePath)
        if isDirectory.boolValue {
            let plugInfoURL = url.appendingPathComponent("plugInfo.json")
            guard fileManager.fileExists(atPath: plugInfoURL.path) else {
                throw USDError.invalidData("plugInfo include directory \(includePath) has no plugInfo.json.")
            }
            return [plugInfoURL.standardizedFileURL]
        }
        return [url.standardizedFileURL]
    }

    private static func absolutePath(for path: String, baseURL: URL) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL.path
    }

    private static func globbedIncludeURLs(for pattern: String) throws -> [URL] {
        let rootPath = globSearchRoot(for: pattern)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw USDError.invalidData("plugInfo include glob root \(rootPath) does not exist.")
        }
        let expression = try NSRegularExpression(pattern: regularExpressionPattern(forGlob: pattern))
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: nil) else {
            throw USDError.invalidData("plugInfo include glob root \(rootPath) cannot be enumerated.")
        }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            if expression.firstMatch(in: path, range: range) != nil {
                matches.append(url.standardizedFileURL)
            }
        }
        guard !matches.isEmpty else {
            throw USDError.invalidData("plugInfo include glob \(pattern) matched no files.")
        }
        return matches.sorted { $0.path < $1.path }
    }

    private static func globSearchRoot(for pattern: String) -> String {
        guard let wildcardIndex = pattern.firstIndex(of: "*") else {
            return URL(fileURLWithPath: pattern).deletingLastPathComponent().path
        }
        let prefix = pattern[..<wildcardIndex]
        guard let slash = prefix.lastIndex(of: "/") else {
            return "."
        }
        let root = prefix[..<slash]
        return root.isEmpty ? "/" : String(root)
    }

    private static func regularExpressionPattern(forGlob glob: String) -> String {
        var pattern = "^"
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            if character == "*" {
                let next = glob.index(after: index)
                if next < glob.endIndex, glob[next] == "*" {
                    pattern += ".*"
                    index = glob.index(after: next)
                } else {
                    pattern += "[^/]*"
                    index = next
                }
                continue
            }
            pattern += NSRegularExpression.escapedPattern(for: String(character))
            index = glob.index(after: index)
        }
        pattern += "$"
        return pattern
    }

    private static func plugin(
        from object: [String: USDPluginMetadataValue],
        baseURL: URL? = nil
    ) throws -> USDPlugin {
        guard let typeName = object["Type"]?.stringValue,
              let type = USDPluginType(rawValue: typeName) else {
            throw USDError.invalidData("plugInfo plugin Type must be library, python, or resource.")
        }
        guard let name = object["Name"]?.stringValue, !name.isEmpty else {
            throw USDError.invalidData("plugInfo plugin Name must be a non-empty string.")
        }
        let rootPath = resolvedPath(object["Root"]?.stringValue ?? ".", baseURL: baseURL)
        let rootURL = URL(fileURLWithPath: rootPath)
        let libraryPath = object["LibraryPath"]?.stringValue.map { resolvedPath($0, baseURL: rootURL) }
        if type == .library && (libraryPath ?? "").isEmpty {
            throw USDError.invalidData("plugInfo library plugin \(name) must define LibraryPath.")
        }
        guard case .dictionary(let info)? = object["Info"] else {
            throw USDError.invalidData("plugInfo plugin \(name) must define an Info object.")
        }
        return USDPlugin(
            type: type,
            name: name,
            rootPath: rootPath,
            libraryPath: libraryPath,
            resourcePath: resolvedPath(object["ResourcePath"]?.stringValue ?? ".", baseURL: rootURL),
            info: info
        )
    }

    private static func resolvedPath(_ path: String, baseURL: URL?) -> String {
        guard let baseURL else {
            return path
        }
        if path.hasPrefix("/") || path.hasPrefix("@") {
            return path
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL.path
    }

    private static func metadataValue(from value: Any) throws -> USDPluginMetadataValue {
        if value is NSNull {
            return .null
        }
        if let string = value as? String {
            return .string(string)
        }
        if let number = value as? NSNumber {
            let typeEncoding = String(cString: number.objCType)
            if typeEncoding == "c" || typeEncoding == "B" {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let array = value as? [Any] {
            return .array(try array.map(metadataValue(from:)))
        }
        if let dictionary = value as? [String: Any] {
            var values: [String: USDPluginMetadataValue] = [:]
            for key in dictionary.keys.sorted() {
                values[key] = try metadataValue(from: dictionary[key] ?? NSNull())
            }
            return .dictionary(values)
        }
        throw USDError.invalidData("plugInfo contains an unsupported JSON value.")
    }

    private static func stripHashComments(from text: String) -> String {
        var output = ""
        var index = text.startIndex
        var isInString = false
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isInString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                isInString = true
                output.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "#" {
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }
}
