public enum USDLayerFieldValue: Sendable, Equatable, Hashable {
    case unmaterializedValue
    case authored(String)
    case timeSamples([SdfTimeSample])
    case dictionary([String: SdfFieldValue])
    case tokenListOperation(SdfListOperation<String>)
    case stringListOperation(SdfListOperation<String>)
    case pathListOperation(SdfListOperation<String>)
    case referenceListOperation(SdfListOperation<SdfReference>)
    case payloadListOperation(SdfListOperation<SdfPayload>)
    case payload(SdfPayload)
}
