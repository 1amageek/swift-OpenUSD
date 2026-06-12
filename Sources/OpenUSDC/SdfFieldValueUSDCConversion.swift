import OpenUSD

public extension SdfFieldValue {
    init(usdcLayerFieldValue value: USDCLayerFieldValue) throws {
        switch value {
        case .unmaterializedValue:
            self = .unmaterializedValue
        case .timeSamples(let samples):
            self = .timeSamples(samples)
        case .bool(let value):
            self = .bool(value)
        case .boolArray(let values):
            self = .boolArray(values)
        case .token(let value):
            self = .token(value)
        case .tokenArray(let values):
            self = .tokenArray(values)
        case .tokenVector(let values):
            self = .tokenVector(values)
        case .string(let value):
            self = .string(value)
        case .stringVector(let values):
            self = .stringVector(values)
        case .assetPath(let value):
            self = .assetPath(value)
        case .dictionary(let values):
            self = .dictionary(try values.mapValues { try SdfFieldValue(usdcLayerFieldValue: $0) })
        case .pathVector(let values):
            self = .pathVector(try values.map { try SdfPath($0) })
        case .variantSelectionMap(let values):
            self = .variantSelectionMap(values)
        case .tokenListOperation(let operation):
            self = .tokenListOperation(operation.toUSDListOperation { $0 })
        case .stringListOperation(let operation):
            self = .stringListOperation(operation.toUSDListOperation { $0 })
        case .pathListOperation(let operation):
            self = .pathListOperation(try operation.toUSDListOperation { try SdfPath($0) })
        case .referenceListOperation(let operation):
            self = .referenceListOperation(try operation.toUSDListOperation { try SdfReference(usdcReference: $0) })
        case .payloadListOperation(let operation):
            self = .payloadListOperation(try operation.toUSDListOperation { try SdfPayload(usdcPayload: $0) })
        case .payload(let payload):
            self = .payload(try SdfPayload(usdcPayload: payload))
        case .int(let value):
            self = .int(value)
        case .double(let value):
            self = .double(value)
        case .doubleArray(let values):
            self = .doubleArray(values)
        case .doubleVector(let values):
            self = .doubleVector(values)
        case .intArray(let values):
            self = .intArray(values)
        case .timeCode(let value):
            self = .timeCode(value)
        case .timeCodeArray(let values):
            self = .timeCodeArray(values)
        case .point2(let value):
            self = .point2(value)
        case .point2Array(let values):
            self = .point2Array(values)
        case .point3(let value):
            self = .point3(value)
        case .point3Array(let values):
            self = .point3Array(values)
        case .layerOffsetVector(let values):
            self = .layerOffsetVector(values)
        case .permission(let value):
            self = .permission(value)
        case .variability(let value):
            self = .variability(value)
        case .specifier(let value):
            self = .specifier(value)
        }
    }
}

private extension SdfReference {
    init(usdcReference: USDCReference) throws {
        self.init(
            assetPath: usdcReference.assetPath,
            primPath: try Self.optionalPath(usdcReference.primPath),
            layerOffset: usdcReference.layerOffset,
            customData: try usdcReference.customData.mapValues { try SdfFieldValue(usdcLayerFieldValue: $0) }
        )
    }

    private static func optionalPath(_ value: String) throws -> SdfPath? {
        guard !value.isEmpty else {
            return nil
        }
        return try SdfPath(value)
    }
}

private extension SdfPayload {
    init(usdcPayload: USDCPayload) throws {
        self.init(
            assetPath: usdcPayload.assetPath,
            primPath: try Self.optionalPath(usdcPayload.primPath),
            layerOffset: usdcPayload.layerOffset
        )
    }

    private static func optionalPath(_ value: String) throws -> SdfPath? {
        guard !value.isEmpty else {
            return nil
        }
        return try SdfPath(value)
    }
}

private extension USDCListOperation {
    func toUSDListOperation<Output: Sendable & Equatable & Hashable>(
        _ transform: (Item) throws -> Output
    ) rethrows -> SdfListOperation<Output> {
        try SdfListOperation(
            isExplicit: isExplicit,
            explicitItems: explicitItems.map(transform),
            addedItems: addedItems.map(transform),
            prependedItems: prependedItems.map(transform),
            appendedItems: appendedItems.map(transform),
            deletedItems: deletedItems.map(transform),
            orderedItems: orderedItems.map(transform)
        )
    }
}
