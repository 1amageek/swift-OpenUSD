public struct USDInMemoryLayerProvider: USDLayerProvider, Sendable, Equatable {
    public var layers: [String: SdfLayer]

    public init(layers: [String: SdfLayer] = [:]) {
        self.layers = layers
    }

    public func resolveIdentifier(_ identifier: String, referencedFrom sourceIdentifier: String?) throws -> String? {
        if let sourceIdentifier,
           let anchoredIdentifier = Self.anchoredIdentifier(identifier, referencedFrom: sourceIdentifier),
           layers[anchoredIdentifier] != nil {
            return anchoredIdentifier
        }
        guard layers[identifier] != nil else {
            return nil
        }
        return identifier
    }

    public func layer(forResolvedIdentifier identifier: String) throws -> SdfLayer? {
        layers[identifier]
    }

    private static func anchoredIdentifier(_ identifier: String, referencedFrom sourceIdentifier: String) -> String? {
        guard !identifier.isEmpty, !identifier.hasPrefix("/") else {
            return nil
        }
        let directory = sourceIdentifier.split(separator: "/").dropLast().joined(separator: "/")
        let joined = directory.isEmpty ? identifier : "\(directory)/\(identifier)"
        return normalizedRelativeIdentifier(joined)
    }

    private static func normalizedRelativeIdentifier(_ identifier: String) -> String? {
        var components: [String] = []
        for component in identifier.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    return nil
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else {
            return nil
        }
        return components.joined(separator: "/")
    }
}
