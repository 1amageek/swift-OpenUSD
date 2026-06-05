public struct USDLayerOffset: Sendable, Equatable, Hashable {
    public var offset: Double
    public var scale: Double

    public init(offset: Double = 0, scale: Double = 1) {
        self.offset = offset
        self.scale = scale
    }

    public static let identity = USDLayerOffset()

    public var isIdentity: Bool {
        offset == 0 && scale == 1
    }

    public func stageTime(forLayerTime layerTime: Double) -> Double {
        layerTime * scale + offset
    }

    public func layerTime(forStageTime stageTime: Double) throws -> Double {
        guard scale != 0 else {
            throw USDImportError.invalidData("USD layer offset scale must be non-zero to invert.")
        }
        return (stageTime - offset) / scale
    }

    public func concatenating(_ rhs: USDLayerOffset) -> USDLayerOffset {
        USDLayerOffset(
            offset: rhs.offset * scale + offset,
            scale: scale * rhs.scale
        )
    }
}
