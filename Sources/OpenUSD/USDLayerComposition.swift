public struct USDLayerComposition: Sendable, Equatable {
    public var sublayers: [USDSublayer]
    public var references: [USDCompositionArc]
    public var payloads: [USDCompositionArc]

    public init(
        sublayers: [USDSublayer] = [],
        references: [USDCompositionArc] = [],
        payloads: [USDCompositionArc] = []
    ) {
        self.sublayers = sublayers
        self.references = references
        self.payloads = payloads
    }

    public init(
        sublayerAssetPaths: [String],
        references: [USDCompositionArc] = [],
        payloads: [USDCompositionArc] = []
    ) {
        self.init(
            sublayers: sublayerAssetPaths.map { USDSublayer(assetPath: $0) },
            references: references,
            payloads: payloads
        )
    }

    public var sublayerAssetPaths: [String] {
        get {
            sublayers.map(\.assetPath)
        }
        set {
            sublayers = newValue.map { USDSublayer(assetPath: $0) }
        }
    }

    @available(*, deprecated, renamed: "sublayerAssetPaths")
    public var subLayerAssetPaths: [String] {
        get {
            sublayerAssetPaths
        }
        set {
            sublayerAssetPaths = newValue
        }
    }

    @available(*, deprecated, renamed: "init(sublayerAssetPaths:references:payloads:)")
    public init(
        subLayerAssetPaths: [String],
        references: [USDCompositionArc] = [],
        payloads: [USDCompositionArc] = []
    ) {
        self.init(
            sublayerAssetPaths: subLayerAssetPaths,
            references: references,
            payloads: payloads
        )
    }

    public var assetPaths: [String] {
        sublayerAssetPaths + references.map(\.assetPath) + payloads.map(\.assetPath)
    }

    public var isEmpty: Bool {
        sublayers.isEmpty && references.isEmpty && payloads.isEmpty
    }
}
