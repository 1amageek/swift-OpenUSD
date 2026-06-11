public struct USDPlugin: Sendable, Equatable, Hashable {
    public var type: USDPluginType
    public var name: String
    public var rootPath: String
    public var libraryPath: String?
    public var resourcePath: String
    public var info: [String: USDPluginMetadataValue]

    public init(
        type: USDPluginType,
        name: String,
        rootPath: String = ".",
        libraryPath: String? = nil,
        resourcePath: String = ".",
        info: [String: USDPluginMetadataValue] = [:]
    ) {
        self.type = type
        self.name = name
        self.rootPath = rootPath
        self.libraryPath = libraryPath
        self.resourcePath = resourcePath
        self.info = info
    }

    public var declaredTypeNames: [String] {
        guard case .dictionary(let types)? = info["Types"] else {
            return []
        }
        return types.keys.sorted()
    }

    public func metadata(forType typeName: String) -> [String: USDPluginMetadataValue]? {
        guard case .dictionary(let types)? = info["Types"],
              case .dictionary(let metadata)? = types[typeName] else {
            return nil
        }
        return metadata
    }
}
