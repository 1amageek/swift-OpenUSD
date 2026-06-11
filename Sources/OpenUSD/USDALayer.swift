public struct USDALayer: Sendable, Equatable {
    public var defaultPrim: String?
    public var metersPerUnit: Double?
    public var upAxis: USDUpAxis?
    public var composition: USDLayerComposition
    public private(set) var specs: [USDLayerSpec]
    public var primTransforms: [String: USDTransformMatrix4x4]
    public var resetXformStackPrimPaths: Set<String>

    /// Maps each spec path to the index of its first occurrence in `specs`.
    /// The specs array remains the source of truth for document order.
    private var specIndexByPath: [String: Int]

    public init(
        defaultPrim: String? = nil,
        metersPerUnit: Double? = nil,
        upAxis: USDUpAxis? = nil,
        composition: USDLayerComposition = USDLayerComposition(),
        specs: [USDLayerSpec] = [],
        primTransforms: [String: USDTransformMatrix4x4] = [:],
        resetXformStackPrimPaths: Set<String> = []
    ) {
        self.defaultPrim = defaultPrim
        self.metersPerUnit = metersPerUnit
        self.upAxis = upAxis
        self.composition = composition
        self.specs = specs
        self.specIndexByPath = Self.makeSpecIndex(for: specs)
        self.primTransforms = primTransforms
        self.resetXformStackPrimPaths = resetXformStackPrimPaths
    }

    public static func == (lhs: USDALayer, rhs: USDALayer) -> Bool {
        lhs.defaultPrim == rhs.defaultPrim
            && lhs.metersPerUnit == rhs.metersPerUnit
            && lhs.upAxis == rhs.upAxis
            && lhs.composition == rhs.composition
            && lhs.primTransforms == rhs.primTransforms
            && lhs.resetXformStackPrimPaths == rhs.resetXformStackPrimPaths
            && lhs.specs == rhs.specs
    }

    public var prims: [USDLayerSpec] {
        specs.filter { $0.specType == .prim }
    }

    public func spec(at path: String) -> USDLayerSpec? {
        guard let index = specIndexByPath[path] else {
            return nil
        }
        return specs[index]
    }

    /// Replaces the spec at the same path in place, or appends the spec while
    /// keeping document order.
    public mutating func setSpec(_ spec: USDLayerSpec) {
        if let index = specIndexByPath[spec.path] {
            specs[index] = spec
        } else {
            specIndexByPath[spec.path] = specs.count
            specs.append(spec)
        }
    }

    /// Replaces the whole spec array, preserving the order of `newSpecs` as
    /// the new document order.
    public mutating func replaceSpecs(_ newSpecs: [USDLayerSpec]) {
        specs = newSpecs
        specIndexByPath = Self.makeSpecIndex(for: newSpecs)
    }

    private static func makeSpecIndex(for specs: [USDLayerSpec]) -> [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(specs.count)
        for (offset, spec) in specs.enumerated() where index[spec.path] == nil {
            index[spec.path] = offset
        }
        return index
    }
}
