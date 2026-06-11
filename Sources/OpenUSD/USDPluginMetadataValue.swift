public enum USDPluginMetadataValue: Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([USDPluginMetadataValue])
    case dictionary([String: USDPluginMetadataValue])
    case null

    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    public var arrayValue: [USDPluginMetadataValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    public var dictionaryValue: [String: USDPluginMetadataValue]? {
        guard case .dictionary(let value) = self else {
            return nil
        }
        return value
    }
}
