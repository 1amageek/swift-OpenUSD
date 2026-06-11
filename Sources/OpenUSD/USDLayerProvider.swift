/// Resolves and loads the layers that participate in stage composition.
///
/// Identifier resolution and layer loading are separate steps so that callers can
/// resolve an authored asset path once and cache loaded layers per resolved identifier.
public protocol USDLayerProvider: Sendable {
    /// Resolves an authored asset path into the canonical identifier of an available layer.
    ///
    /// Resolution anchored to `sourceIdentifier` must take precedence over global
    /// resolution so that relative asset paths resolve against the referencing layer
    /// before falling back to absolute lookup.
    /// Returns nil when no available layer matches the identifier.
    func resolveIdentifier(_ identifier: String, referencedFrom sourceIdentifier: String?) throws -> String?

    /// Loads the layer for an identifier previously returned by
    /// `resolveIdentifier(_:referencedFrom:)`.
    /// Layers are vended in the format-agnostic Sdf data model so that
    /// providers can serve USDA, USDC, or authored in-memory layers.
    /// Returns nil when the layer is not available.
    func layer(forResolvedIdentifier identifier: String) throws -> SdfLayer?
}

extension USDLayerProvider {
    /// Resolves `identifier` and loads the matching layer in one step.
    public func layer(identifier: String, referencedFrom sourceIdentifier: String?) throws -> SdfLayer? {
        guard let resolvedIdentifier = try resolveIdentifier(identifier, referencedFrom: sourceIdentifier) else {
            return nil
        }
        return try layer(forResolvedIdentifier: resolvedIdentifier)
    }
}
