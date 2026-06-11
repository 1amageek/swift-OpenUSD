import Foundation

struct USDStageCompositionResolver: Sendable {
    var rootLayer: USDALayer
    var rootIdentifier: String
    var provider: any USDLayerProvider

    func flattenedLayer() throws -> USDALayer {
        try flattenedLayer(
            rootLayer,
            identifier: rootIdentifier,
            targetPrimPath: nil,
            ancestorKeys: [],
            cache: USDStageCompositionCache()
        )
    }

    // MARK: - Flattening

    private func flattenedLayer(
        _ layer: USDALayer,
        identifier: String,
        targetPrimPath: String?,
        ancestorKeys: Set<USDStageCompositionKey>,
        cache: USDStageCompositionCache
    ) throws -> USDALayer {
        let key = USDStageCompositionKey(identifier: identifier, targetPrimPath: targetPrimPath)
        if let cachedLayer = cache.flattenedLayers[key] {
            return cachedLayer
        }
        guard !ancestorKeys.contains(key) else {
            throw USDError.invalidData("USDStage composition cycle detected at \(identifier).")
        }
        var descendantAncestorKeys = ancestorKeys
        descendantAncestorKeys.insert(key)

        let layerStack = try layerStackEntries(
            rootLayer: layer,
            rootIdentifier: identifier,
            layer: layer,
            identifier: identifier,
            layerOffset: .identity,
            ancestorKeys: descendantAncestorKeys,
            cache: cache
        )

        var accumulator = USDStageLayerAccumulator()
        let arcs = try compositionArcs(in: layerStack, targetPrimPath: targetPrimPath)
        for arc in arcs.payloads.reversed() {
            let payloadLayer = try flattenedReferencedLayer(
                arc: arc,
                ancestorKeys: descendantAncestorKeys,
                cache: cache
            )
            try accumulator.merge(strongerLayer: payloadLayer)
        }
        for arc in arcs.references.reversed() {
            let referenceLayer = try flattenedReferencedLayer(
                arc: arc,
                ancestorKeys: descendantAncestorKeys,
                cache: cache
            )
            try accumulator.merge(strongerLayer: referenceLayer)
        }

        try accumulator.merge(strongerLayer: localLayerStack(from: layerStack))
        var result = accumulator.layer
        result.composition = USDLayerComposition()
        cache.flattenedLayers[key] = result
        return result
    }

    private func layerStackEntries(
        rootLayer: USDALayer,
        rootIdentifier: String,
        layer: USDALayer,
        identifier: String,
        layerOffset: SdfLayerOffset,
        ancestorKeys: Set<USDStageCompositionKey>,
        cache: USDStageCompositionCache
    ) throws -> [USDStageLayerStackEntry] {
        var entries: [USDStageLayerStackEntry] = []
        for sublayer in layer.composition.sublayers.reversed() {
            let sublayerIdentifier = try resolvedLayerIdentifier(
                sublayer.assetPath,
                referencedFrom: identifier
            )
            let sublayerKey = USDStageCompositionKey(identifier: sublayerIdentifier, targetPrimPath: nil)
            guard !ancestorKeys.contains(sublayerKey) else {
                throw USDError.invalidData("USDStage composition cycle detected at \(sublayerIdentifier).")
            }
            var descendantAncestorKeys = ancestorKeys
            descendantAncestorKeys.insert(sublayerKey)
            let sublayerLayer = try requireLayer(resolvedIdentifier: sublayerIdentifier, cache: cache)
            entries.append(contentsOf: try layerStackEntries(
                rootLayer: rootLayer,
                rootIdentifier: rootIdentifier,
                layer: sublayerLayer,
                identifier: sublayerIdentifier,
                layerOffset: layerOffset.concatenating(sublayer.layerOffset),
                ancestorKeys: descendantAncestorKeys,
                cache: cache
            ))
        }
        entries.append(USDStageLayerStackEntry(
            layer: layer,
            identifier: identifier,
            layerOffset: layerOffset,
            stackRootLayer: rootLayer,
            stackRootIdentifier: rootIdentifier
        ))
        return entries
    }

    private func localLayerStack(from entries: [USDStageLayerStackEntry]) throws -> USDALayer {
        var accumulator = USDStageLayerAccumulator()
        for entry in entries {
            var entryLayer = withoutCompositionFields(in: entry.layer)
            if entry.identifier != entry.stackRootIdentifier {
                stripStackRootOnlyLayerMetadata(from: &entryLayer)
            }
            try accumulator.merge(strongerLayer: applying(entry.layerOffset, to: entryLayer))
        }
        var result = accumulator.layer
        result.composition = USDLayerComposition()
        return result
    }

    private func withoutCompositionFields(in layer: USDALayer) -> USDALayer {
        var strippedLayer = layer
        strippedLayer.composition = USDLayerComposition()
        strippedLayer.replaceSpecs(strippedLayer.specs.map { spec in
            var strippedSpec = spec
            if strippedSpec.path == "/" {
                removeField("subLayers", from: &strippedSpec)
                removeField("subLayerOffsets", from: &strippedSpec)
            }
            if strippedSpec.specType == .prim {
                removeField("references", from: &strippedSpec)
                removeField("payload", from: &strippedSpec)
            }
            return strippedSpec
        })
        return strippedLayer
    }

    /// Removes layer metadata that upstream resolves from the layer-stack root only,
    /// so that sublayers cannot contribute it to the flattened result.
    private func stripStackRootOnlyLayerMetadata(from layer: inout USDALayer) {
        layer.defaultPrim = nil
        layer.replaceSpecs(layer.specs.map { spec in
            guard spec.path == "/" else {
                return spec
            }
            var strippedSpec = spec
            removeField("defaultPrim", from: &strippedSpec)
            return strippedSpec
        })
    }

    private func removeField(_ fieldName: String, from spec: inout USDLayerSpec) {
        spec.fieldNames.removeAll { $0 == fieldName }
        spec.fields.removeValue(forKey: fieldName)
    }

    private func flattenedReferencedLayer(
        arc: USDStageResolvedCompositionArc,
        ancestorKeys: Set<USDStageCompositionKey>,
        cache: USDStageCompositionCache
    ) throws -> USDALayer {
        let targetIdentifier: String
        let targetLayer: USDALayer
        if arc.assetPath.isEmpty {
            targetIdentifier = arc.stackRootIdentifier
            targetLayer = arc.stackRootLayer
        } else {
            targetIdentifier = try resolvedLayerIdentifier(arc.assetPath, referencedFrom: arc.sourceIdentifier)
            targetLayer = try requireLayer(resolvedIdentifier: targetIdentifier, cache: cache)
        }

        let effectiveTargetPrimPath = try self.effectiveTargetPrimPath(
            authoredTargetPrimPath: arc.targetPrimPath,
            targetLayer: targetLayer,
            targetIdentifier: targetIdentifier
        )
        let flattenedTargetLayer = try flattenedLayer(
            targetLayer,
            identifier: targetIdentifier,
            targetPrimPath: effectiveTargetPrimPath,
            ancestorKeys: ancestorKeys,
            cache: cache
        )
        guard flattenedTargetLayer.spec(at: effectiveTargetPrimPath)?.specType == .prim else {
            throw USDError.invalidData(
                "USDStage composition target prim \(effectiveTargetPrimPath) was not found in layer \(targetIdentifier)."
            )
        }
        let rewrittenLayer = try rewrite(
            flattenedTargetLayer,
            sourceTargetPrimPath: effectiveTargetPrimPath,
            sitePrimPath: arc.sitePrimPath
        )
        return try applying(arc.layerOffset, to: rewrittenLayer)
    }

    // MARK: - Layer resolution

    private func requireLayer(resolvedIdentifier: String, cache: USDStageCompositionCache) throws -> USDALayer {
        if let loadedLayer = cache.loadedLayers[resolvedIdentifier] {
            return loadedLayer
        }
        guard let layer = try provider.layer(forResolvedIdentifier: resolvedIdentifier) else {
            throw USDError.invalidData("USDStage composition could not load layer \(resolvedIdentifier).")
        }
        let usdLayer = layer.toUSDALayer()
        cache.loadedLayers[resolvedIdentifier] = usdLayer
        return usdLayer
    }

    private func resolvedLayerIdentifier(_ identifier: String, referencedFrom sourceIdentifier: String) throws -> String {
        guard let resolvedIdentifier = try provider.resolveIdentifier(identifier, referencedFrom: sourceIdentifier) else {
            throw USDError.invalidData(
                "USDStage composition could not resolve layer \(identifier) referenced from \(sourceIdentifier)."
            )
        }
        return resolvedIdentifier
    }

    private func effectiveTargetPrimPath(
        authoredTargetPrimPath: String?,
        targetLayer: USDALayer,
        targetIdentifier: String
    ) throws -> String {
        if let authoredTargetPrimPath, !authoredTargetPrimPath.isEmpty, authoredTargetPrimPath != "/" {
            return authoredTargetPrimPath
        }
        guard let defaultPrim = targetLayer.defaultPrim, !defaultPrim.isEmpty else {
            throw USDError.invalidData(
                "USDStage composition target layer \(targetIdentifier) has no defaultPrim for an unqualified reference."
            )
        }
        return "/\(defaultPrim)"
    }

    // MARK: - Composition arcs

    private func compositionArcs(
        in entries: [USDStageLayerStackEntry],
        targetPrimPath: String?
    ) throws -> (references: [USDStageResolvedCompositionArc], payloads: [USDStageResolvedCompositionArc]) {
        var referencesBySite: [String: [USDStageAuthoredCompositionArc<SdfReference>]] = [:]
        var payloadsBySite: [String: [USDStageAuthoredCompositionArc<SdfPayload>]] = [:]
        for entry in entries {
            let typedReferenceSites = Set(entry.layer.specs.compactMap { spec -> String? in
                spec.fields["references"] == nil ? nil : spec.path
            })
            let typedPayloadSites = Set(entry.layer.specs.compactMap { spec -> String? in
                spec.fields["payload"] == nil ? nil : spec.path
            })
            let compositionReferences = Dictionary(grouping: entry.layer.composition.references) { $0.sitePrimPath ?? "" }
            for sitePrimPath in compositionReferences.keys.sorted() where !typedReferenceSites.contains(sitePrimPath) {
                guard isRelevantArcSite(sitePrimPath, targetPrimPath: targetPrimPath) else {
                    continue
                }
                var authoredArcs: [USDStageAuthoredCompositionArc<SdfReference>] = []
                for arc in compositionReferences[sitePrimPath] ?? [] {
                    if let authoredArc = try authoredReferenceArc(from: arc, entry: entry) {
                        authoredArcs.append(authoredArc)
                    }
                }
                referencesBySite[sitePrimPath] = authoredArcs
            }
            let compositionPayloads = Dictionary(grouping: entry.layer.composition.payloads) { $0.sitePrimPath ?? "" }
            for sitePrimPath in compositionPayloads.keys.sorted() where !typedPayloadSites.contains(sitePrimPath) {
                guard isRelevantArcSite(sitePrimPath, targetPrimPath: targetPrimPath) else {
                    continue
                }
                var authoredArcs: [USDStageAuthoredCompositionArc<SdfPayload>] = []
                for arc in compositionPayloads[sitePrimPath] ?? [] {
                    if let authoredArc = try authoredPayloadArc(from: arc, entry: entry) {
                        authoredArcs.append(authoredArc)
                    }
                }
                payloadsBySite[sitePrimPath] = authoredArcs
            }
            for spec in entry.layer.specs where spec.specType == .prim && isRelevantArcSite(spec.path, targetPrimPath: targetPrimPath) {
                if case .referenceListOperation(let operation)? = spec.fields["references"] {
                    referencesBySite[spec.path] = applyReferenceListOperation(
                        operation,
                        at: spec.path,
                        in: entry,
                        to: referencesBySite[spec.path] ?? []
                    )
                }
                if case .payloadListOperation(let operation)? = spec.fields["payload"] {
                    payloadsBySite[spec.path] = applyPayloadListOperation(
                        operation,
                        at: spec.path,
                        in: entry,
                        to: payloadsBySite[spec.path] ?? []
                    )
                } else if case .payload(let payload)? = spec.fields["payload"] {
                    payloadsBySite[spec.path] = [authoredPayloadArc(from: payload, sitePrimPath: spec.path, entry: entry)]
                }
            }
        }
        // Direct arcs (authored on deeper prims) are stronger than ancestral arcs, so
        // order sites by descending namespace depth; the merge loop consumes the arrays
        // strongest-first by merging them in reverse.
        let referenceSites = referencesBySite.keys.sorted(by: isStrongerArcSite)
        let payloadSites = payloadsBySite.keys.sorted(by: isStrongerArcSite)
        return (
            referenceSites.flatMap { referencesBySite[$0]?.map(\.resolvedArc) ?? [] },
            payloadSites.flatMap { payloadsBySite[$0]?.map(\.resolvedArc) ?? [] }
        )
    }

    private func isStrongerArcSite(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = namespaceDepth(of: lhs)
        let rhsDepth = namespaceDepth(of: rhs)
        guard lhsDepth == rhsDepth else {
            return lhsDepth > rhsDepth
        }
        return lhs < rhs
    }

    private func namespaceDepth(of primPath: String) -> Int {
        primPath.split(separator: "/").count
    }

    private func isRelevantArcSite(_ sitePrimPath: String, targetPrimPath: String?) -> Bool {
        guard !sitePrimPath.isEmpty else {
            return false
        }
        guard let targetPrimPath, targetPrimPath != "/" else {
            return true
        }
        return sitePrimPath == targetPrimPath
            || sitePrimPath.hasPrefix(targetPrimPath + "/")
            || targetPrimPath.hasPrefix(sitePrimPath + "/")
    }

    private func authoredReferenceArc(
        from arc: USDCompositionArc,
        entry: USDStageLayerStackEntry
    ) throws -> USDStageAuthoredCompositionArc<SdfReference>? {
        guard let sitePrimPath = arc.sitePrimPath, !sitePrimPath.isEmpty else {
            return nil
        }
        return authoredReferenceArc(
            from: SdfReference(
                assetPath: arc.assetPath,
                primPath: try sdfPath(from: arc.targetPrimPath),
                layerOffset: arc.layerOffset
            ),
            sitePrimPath: sitePrimPath,
            entry: entry
        )
    }

    private func authoredReferenceArc(
        from reference: SdfReference,
        sitePrimPath: String,
        entry: USDStageLayerStackEntry
    ) -> USDStageAuthoredCompositionArc<SdfReference> {
        USDStageAuthoredCompositionArc(
            item: reference,
            resolvedArc: USDStageResolvedCompositionArc(
                assetPath: reference.assetPath,
                sitePrimPath: sitePrimPath,
                targetPrimPath: reference.primPath?.rawValue,
                layerOffset: entry.layerOffset.concatenating(reference.layerOffset),
                sourceIdentifier: entry.identifier,
                stackRootLayer: entry.stackRootLayer,
                stackRootIdentifier: entry.stackRootIdentifier
            )
        )
    }

    private func authoredPayloadArc(
        from arc: USDCompositionArc,
        entry: USDStageLayerStackEntry
    ) throws -> USDStageAuthoredCompositionArc<SdfPayload>? {
        guard let sitePrimPath = arc.sitePrimPath, !sitePrimPath.isEmpty else {
            return nil
        }
        return authoredPayloadArc(
            from: SdfPayload(
                assetPath: arc.assetPath,
                primPath: try sdfPath(from: arc.targetPrimPath),
                layerOffset: arc.layerOffset
            ),
            sitePrimPath: sitePrimPath,
            entry: entry
        )
    }

    private func authoredPayloadArc(
        from payload: SdfPayload,
        sitePrimPath: String,
        entry: USDStageLayerStackEntry
    ) -> USDStageAuthoredCompositionArc<SdfPayload> {
        USDStageAuthoredCompositionArc(
            item: payload,
            resolvedArc: USDStageResolvedCompositionArc(
                assetPath: payload.assetPath,
                sitePrimPath: sitePrimPath,
                targetPrimPath: payload.primPath?.rawValue,
                layerOffset: entry.layerOffset.concatenating(payload.layerOffset),
                sourceIdentifier: entry.identifier,
                stackRootLayer: entry.stackRootLayer,
                stackRootIdentifier: entry.stackRootIdentifier
            )
        )
    }

    private func sdfPath(from rawValue: String?) throws -> SdfPath? {
        guard let rawValue else {
            return nil
        }
        return try SdfPath(rawValue)
    }

    // MARK: - Arc list operations

    private func applyReferenceListOperation(
        _ operation: SdfListOperation<SdfReference>,
        at sitePrimPath: String,
        in entry: USDStageLayerStackEntry,
        to baseItems: [USDStageAuthoredCompositionArc<SdfReference>]
    ) -> [USDStageAuthoredCompositionArc<SdfReference>] {
        applyListOperation(operation, to: baseItems) {
            authoredReferenceArc(from: $0, sitePrimPath: sitePrimPath, entry: entry)
        }
    }

    private func applyPayloadListOperation(
        _ operation: SdfListOperation<SdfPayload>,
        at sitePrimPath: String,
        in entry: USDStageLayerStackEntry,
        to baseItems: [USDStageAuthoredCompositionArc<SdfPayload>]
    ) -> [USDStageAuthoredCompositionArc<SdfPayload>] {
        applyListOperation(operation, to: baseItems) {
            authoredPayloadArc(from: $0, sitePrimPath: sitePrimPath, entry: entry)
        }
    }

    /// Applies a list operation to already-resolved arcs following upstream `SdfListOp`
    /// semantics: explicit replaces the list entirely, deleted/added/prepended/appended/
    /// ordered apply in that order, added never moves an existing arc, and prepended or
    /// appended reposition existing arcs without re-anchoring them.
    private func applyListOperation<Item: Sendable & Equatable & Hashable>(
        _ operation: SdfListOperation<Item>,
        to baseItems: [USDStageAuthoredCompositionArc<Item>],
        makeItem: (Item) -> USDStageAuthoredCompositionArc<Item>
    ) -> [USDStageAuthoredCompositionArc<Item>] {
        if operation.isExplicit {
            return unique(operation.explicitItems.map(makeItem))
        }
        var arcs = unique(baseItems)
        if !operation.deletedItems.isEmpty {
            let deletedItems = Set(operation.deletedItems)
            arcs.removeAll { deletedItems.contains($0.item) }
        }
        var presentItems = Set(arcs.map(\.item))
        for item in operation.addedItems where presentItems.insert(item).inserted {
            arcs.append(makeItem(item))
        }
        if !operation.prependedItems.isEmpty {
            let prependedItems = SdfListOperation<Item>.uniqueItems(operation.prependedItems)
            arcs = movedArcs(for: prependedItems, in: &arcs, makeItem: makeItem) + arcs
            presentItems.formUnion(prependedItems)
        }
        if !operation.appendedItems.isEmpty {
            let appendedItems = SdfListOperation<Item>.uniqueItems(operation.appendedItems)
            let movedArcs = movedArcs(for: appendedItems, in: &arcs, makeItem: makeItem)
            arcs.append(contentsOf: movedArcs)
            presentItems.formUnion(appendedItems)
        }
        guard !operation.orderedItems.isEmpty else {
            return arcs
        }
        return reordered(arcs, by: operation.orderedItems)
    }

    /// Extracts the arcs matching `items` from `arcs` (removing them) and returns them in
    /// item order, reusing existing arcs so repositioning does not re-anchor them.
    private func movedArcs<Item: Sendable & Equatable & Hashable>(
        for items: [Item],
        in arcs: inout [USDStageAuthoredCompositionArc<Item>],
        makeItem: (Item) -> USDStageAuthoredCompositionArc<Item>
    ) -> [USDStageAuthoredCompositionArc<Item>] {
        let itemSet = Set(items)
        var existingArcsByItem: [Item: USDStageAuthoredCompositionArc<Item>] = [:]
        for arc in arcs where itemSet.contains(arc.item) && existingArcsByItem[arc.item] == nil {
            existingArcsByItem[arc.item] = arc
        }
        arcs.removeAll { itemSet.contains($0.item) }
        return items.map { existingArcsByItem[$0] ?? makeItem($0) }
    }

    /// Reorders arcs following upstream `SdfListOp` ordered-item semantics; see
    /// `SdfListOperation.reordered(_:by:)`.
    private func reordered<Item: Sendable & Equatable & Hashable>(
        _ arcs: [USDStageAuthoredCompositionArc<Item>],
        by orderedItems: [Item]
    ) -> [USDStageAuthoredCompositionArc<Item>] {
        let uniqueOrder = SdfListOperation<Item>.uniqueItems(orderedItems)
        let orderedSet = Set(uniqueOrder)
        var scratch = arcs
        var reorderedRuns: [USDStageAuthoredCompositionArc<Item>] = []
        for orderedItem in uniqueOrder {
            guard let startIndex = scratch.firstIndex(where: { $0.item == orderedItem }) else {
                continue
            }
            var endIndex = scratch.count
            for index in (startIndex + 1)..<scratch.count where orderedSet.contains(scratch[index].item) {
                endIndex = index
                break
            }
            reorderedRuns.append(contentsOf: scratch[startIndex..<endIndex])
            scratch.removeSubrange(startIndex..<endIndex)
        }
        return scratch + reorderedRuns
    }

    private func unique<Item: Sendable & Equatable & Hashable>(
        _ arcs: [USDStageAuthoredCompositionArc<Item>]
    ) -> [USDStageAuthoredCompositionArc<Item>] {
        var seenItems: Set<Item> = []
        var result: [USDStageAuthoredCompositionArc<Item>] = []
        for arc in arcs where seenItems.insert(arc.item).inserted {
            result.append(arc)
        }
        return result
    }

    // MARK: - Path rewriting across an arc

    private func rewrite(
        _ layer: USDALayer,
        sourceTargetPrimPath: String,
        sitePrimPath: String
    ) throws -> USDALayer {
        var rewrittenSpecs: [USDLayerSpec] = []
        for spec in layer.specs {
            guard let rewrittenPath = rewrittenPath(
                spec.path,
                sourceTargetPrimPath: sourceTargetPrimPath,
                sitePrimPath: sitePrimPath
            ) else {
                continue
            }
            var rewrittenSpec = spec
            rewrittenSpec.path = rewrittenPath
            rewrittenSpec.fields = spec.fields.mapValues {
                rewriteFieldValue($0, sourceTargetPrimPath: sourceTargetPrimPath, sitePrimPath: sitePrimPath)
            }
            rewrittenSpecs.append(rewrittenSpec)
        }

        var rewrittenTransforms: [String: USDTransformMatrix4x4] = [:]
        for (path, transform) in layer.primTransforms {
            guard let rewrittenPath = rewrittenPath(
                path,
                sourceTargetPrimPath: sourceTargetPrimPath,
                sitePrimPath: sitePrimPath
            ) else {
                continue
            }
            rewrittenTransforms[rewrittenPath] = transform
        }
        let rewrittenResetPaths = Set(layer.resetXformStackPrimPaths.compactMap {
            rewrittenPath($0, sourceTargetPrimPath: sourceTargetPrimPath, sitePrimPath: sitePrimPath)
        })
        // The referenced layer's own layer metadata must not leak into the flattened
        // root layer; the root layer stack alone provides the stage metadata.
        return USDALayer(
            defaultPrim: nil,
            metersPerUnit: nil,
            upAxis: nil,
            composition: USDLayerComposition(),
            specs: rewrittenSpecs,
            primTransforms: rewrittenTransforms,
            resetXformStackPrimPaths: rewrittenResetPaths
        )
    }

    private func rewrittenPath(
        _ path: String,
        sourceTargetPrimPath: String,
        sitePrimPath: String
    ) -> String? {
        if path == "/" {
            return nil
        }
        if path == sourceTargetPrimPath {
            return sitePrimPath
        }
        for separator in ["/", ".", "{"] {
            let prefix = sourceTargetPrimPath + separator
            if path.hasPrefix(prefix) {
                return sitePrimPath + separator + path.dropFirst(prefix.count)
            }
        }
        return nil
    }

    private func rewriteFieldValue(
        _ value: USDLayerFieldValue,
        sourceTargetPrimPath: String,
        sitePrimPath: String
    ) -> USDLayerFieldValue {
        switch value {
        case .pathListOperation(let operation):
            return .pathListOperation(
                rewriteOperation(operation, sourceTargetPrimPath: sourceTargetPrimPath, sitePrimPath: sitePrimPath)
            )
        default:
            return value
        }
    }

    /// Rewrites every path in the operation across the arc. Paths that cannot be mapped
    /// (they point outside the referenced subtree) are dropped, matching upstream
    /// `PcpMapFunction` semantics.
    private func rewriteOperation(
        _ operation: SdfListOperation<String>,
        sourceTargetPrimPath: String,
        sitePrimPath: String
    ) -> SdfListOperation<String> {
        func rewriteItems(_ items: [String]) -> [String] {
            items.compactMap {
                rewrittenPath($0, sourceTargetPrimPath: sourceTargetPrimPath, sitePrimPath: sitePrimPath)
            }
        }
        return SdfListOperation(
            isExplicit: operation.isExplicit,
            explicitItems: rewriteItems(operation.explicitItems),
            addedItems: rewriteItems(operation.addedItems),
            prependedItems: rewriteItems(operation.prependedItems),
            appendedItems: rewriteItems(operation.appendedItems),
            deletedItems: rewriteItems(operation.deletedItems),
            orderedItems: rewriteItems(operation.orderedItems)
        )
    }

    // MARK: - Layer offsets

    private func applying(_ layerOffset: SdfLayerOffset, to layer: USDALayer) throws -> USDALayer {
        guard !layerOffset.isIdentity else {
            return layer
        }
        var adjustedLayer = layer
        adjustedLayer.replaceSpecs(try layer.specs.map { spec in
            try applying(layerOffset, to: spec)
        })
        adjustedLayer.composition.sublayers = layer.composition.sublayers.map {
            USDSublayer(assetPath: $0.assetPath, layerOffset: layerOffset.concatenating($0.layerOffset))
        }
        adjustedLayer.composition.references = layer.composition.references.map {
            USDCompositionArc(
                assetPath: $0.assetPath,
                sitePrimPath: $0.sitePrimPath,
                targetPrimPath: $0.targetPrimPath,
                layerOffset: layerOffset.concatenating($0.layerOffset)
            )
        }
        adjustedLayer.composition.payloads = layer.composition.payloads.map {
            USDCompositionArc(
                assetPath: $0.assetPath,
                sitePrimPath: $0.sitePrimPath,
                targetPrimPath: $0.targetPrimPath,
                layerOffset: layerOffset.concatenating($0.layerOffset)
            )
        }
        return adjustedLayer
    }

    private func applying(_ layerOffset: SdfLayerOffset, to spec: USDLayerSpec) throws -> USDLayerSpec {
        var adjustedSpec = spec
        if let timeSamplesValue = spec.fields["timeSamples"] {
            guard case .authored(let timeSamplesText) = timeSamplesValue else {
                throw USDError.unsupportedFeature(
                    "USDStage composition cannot apply a layer offset to non-authored timeSamples at \(spec.path)."
                )
            }
            adjustedSpec.fields["timeSamples"] = .authored(
                try remappedTimeSamplesText(timeSamplesText, applying: layerOffset, at: spec.path)
            )
        }
        if spec.path == "/" {
            for fieldName in ["startTimeCode", "endTimeCode"] {
                guard let fieldValue = spec.fields[fieldName] else {
                    continue
                }
                guard case .authored(let timeCodeText) = fieldValue,
                      let timeCode = Double(timeCodeText.trimmingCharacters(in: .whitespacesAndNewlines)),
                      timeCode.isFinite else {
                    throw USDError.unsupportedFeature(
                        "USDStage composition cannot apply a layer offset to non-numeric \(fieldName) layer metadata."
                    )
                }
                adjustedSpec.fields[fieldName] = .authored(
                    try formattedTimeCode(layerOffset.stageTime(forLayerTime: timeCode), at: spec.path)
                )
            }
        }
        return adjustedSpec
    }

    private func remappedTimeSamplesText(
        _ text: String,
        applying layerOffset: SdfLayerOffset,
        at path: String
    ) throws -> String {
        guard layerOffset.scale != 0 else {
            throw USDError.invalidData(
                "USDStage composition cannot remap timeSamples at \(path) with a zero layer offset scale."
            )
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count >= 2, trimmedText.hasPrefix("{"), trimmedText.hasSuffix("}") else {
            throw malformedTimeSamplesError(at: path)
        }
        let body = String(trimmedText.dropFirst().dropLast())
        let entries = try timeSampleEntries(in: body, at: path)
        guard !entries.isEmpty else {
            return trimmedText
        }
        let lines = try entries.map { entry in
            let remappedTimeCode = try formattedTimeCode(layerOffset.stageTime(forLayerTime: entry.timeCode), at: path)
            return "    \(remappedTimeCode): \(entry.value)"
        }
        return "{\n\(lines.joined(separator: ",\n"))\n}"
    }

    private func timeSampleEntries(
        in body: String,
        at path: String
    ) throws -> [(timeCode: Double, value: String)] {
        var entries: [(timeCode: Double, value: String)] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            if body[cursor].isWhitespace || body[cursor] == "," {
                cursor = body.index(after: cursor)
                continue
            }
            let timeStart = cursor
            while cursor < body.endIndex, isTimeCodeLiteralCharacter(body[cursor]) {
                cursor = body.index(after: cursor)
            }
            guard timeStart < cursor,
                  let timeCode = Double(body[timeStart..<cursor]),
                  timeCode.isFinite else {
                throw malformedTimeSamplesError(at: path)
            }
            while cursor < body.endIndex, body[cursor].isWhitespace {
                cursor = body.index(after: cursor)
            }
            guard cursor < body.endIndex, body[cursor] == ":" else {
                throw malformedTimeSamplesError(at: path)
            }
            cursor = body.index(after: cursor)
            let value = try scanTimeSampleValue(in: body, cursor: &cursor, at: path)
            entries.append((timeCode: timeCode, value: value))
        }
        return entries
    }

    private func isTimeCodeLiteralCharacter(_ character: Character) -> Bool {
        character.isNumber
            || character == "."
            || character == "+"
            || character == "-"
            || character == "e"
            || character == "E"
    }

    private func scanTimeSampleValue(
        in body: String,
        cursor: inout String.Index,
        at path: String
    ) throws -> String {
        while cursor < body.endIndex, body[cursor].isWhitespace {
            cursor = body.index(after: cursor)
        }
        let valueStart = cursor
        var openBrackets: [Character] = []
        scan: while cursor < body.endIndex {
            let character = body[cursor]
            switch character {
            case "\"", "'":
                try skipStringLiteral(in: body, cursor: &cursor, at: path)
                continue scan
            case "[", "(", "{":
                openBrackets.append(character)
            case "]", ")", "}":
                guard let openBracket = openBrackets.popLast(),
                      isMatchingBracketPair(open: openBracket, close: character) else {
                    throw malformedTimeSamplesError(at: path)
                }
            case ",":
                if openBrackets.isEmpty {
                    break scan
                }
            default:
                break
            }
            cursor = body.index(after: cursor)
        }
        guard openBrackets.isEmpty else {
            throw malformedTimeSamplesError(at: path)
        }
        let value = body[valueStart..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw malformedTimeSamplesError(at: path)
        }
        return value
    }

    private func isMatchingBracketPair(open: Character, close: Character) -> Bool {
        switch (open, close) {
        case ("[", "]"), ("(", ")"), ("{", "}"):
            return true
        default:
            return false
        }
    }

    private func skipStringLiteral(
        in body: String,
        cursor: inout String.Index,
        at path: String
    ) throws {
        let quote = body[cursor]
        let tripleQuote = String(repeating: quote, count: 3)
        if body[cursor...].hasPrefix(tripleQuote) {
            cursor = body.index(cursor, offsetBy: 3)
            while cursor < body.endIndex {
                if body[cursor] == "\\" {
                    cursor = body.index(after: cursor)
                    guard cursor < body.endIndex else {
                        break
                    }
                    cursor = body.index(after: cursor)
                    continue
                }
                if body[cursor...].hasPrefix(tripleQuote) {
                    cursor = body.index(cursor, offsetBy: 3)
                    return
                }
                cursor = body.index(after: cursor)
            }
            throw malformedTimeSamplesError(at: path)
        }
        cursor = body.index(after: cursor)
        while cursor < body.endIndex {
            let character = body[cursor]
            if character == "\\" {
                cursor = body.index(after: cursor)
                guard cursor < body.endIndex else {
                    break
                }
                cursor = body.index(after: cursor)
                continue
            }
            cursor = body.index(after: cursor)
            if character == quote {
                return
            }
        }
        throw malformedTimeSamplesError(at: path)
    }

    private func formattedTimeCode(_ value: Double, at path: String) throws -> String {
        guard value.isFinite else {
            throw USDError.invalidData(
                "USDStage composition produced a non-finite remapped timeCode at \(path)."
            )
        }
        if value.rounded() == value, value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private func malformedTimeSamplesError(at path: String) -> USDError {
        USDError.unsupportedFeature(
            "USDStage composition cannot remap timeSamples at \(path) because the authored payload could not be parsed."
        )
    }
}

// MARK: - Supporting types

private final class USDStageCompositionCache {
    var flattenedLayers: [USDStageCompositionKey: USDALayer] = [:]
    var loadedLayers: [String: USDALayer] = [:]
}

private struct USDStageCompositionKey: Sendable, Hashable {
    var identifier: String
    var targetPrimPath: String?
}

private struct USDStageLayerStackEntry: Sendable {
    var layer: USDALayer
    var identifier: String
    var layerOffset: SdfLayerOffset
    var stackRootLayer: USDALayer
    var stackRootIdentifier: String
}

private struct USDStageAuthoredCompositionArc<Item: Sendable & Equatable & Hashable>: Sendable {
    var item: Item
    var resolvedArc: USDStageResolvedCompositionArc
}

private struct USDStageResolvedCompositionArc: Sendable {
    var assetPath: String
    var sitePrimPath: String
    var targetPrimPath: String?
    var layerOffset: SdfLayerOffset
    var sourceIdentifier: String
    var stackRootLayer: USDALayer
    var stackRootIdentifier: String
}

/// Accumulates layers from weakest to strongest, merging each stronger layer over the
/// accumulated result. Spec lookup stays O(1) through the layer's own path index.
private struct USDStageLayerAccumulator {
    private(set) var layer = USDALayer()

    mutating func merge(strongerLayer: USDALayer) throws {
        layer.defaultPrim = strongerLayer.defaultPrim ?? layer.defaultPrim
        layer.metersPerUnit = strongerLayer.metersPerUnit ?? layer.metersPerUnit
        layer.upAxis = strongerLayer.upAxis ?? layer.upAxis
        for spec in strongerLayer.specs {
            try merge(strongerSpec: spec)
        }
        for (path, transform) in strongerLayer.primTransforms {
            layer.primTransforms[path] = transform
        }
        layer.resetXformStackPrimPaths.formUnion(strongerLayer.resetXformStackPrimPaths)
    }

    private mutating func merge(strongerSpec: USDLayerSpec) throws {
        guard let weakerSpec = layer.spec(at: strongerSpec.path) else {
            layer.setSpec(strongerSpec)
            return
        }
        layer.setSpec(try Self.mergedSpec(weakerSpec: weakerSpec, strongerSpec: strongerSpec))
    }

    private static func mergedSpec(weakerSpec: USDLayerSpec, strongerSpec: USDLayerSpec) throws -> USDLayerSpec {
        var merged = weakerSpec
        merged.specType = strongerSpec.specType
        merged.specifier = composedSpecifier(weaker: weakerSpec.specifier, stronger: strongerSpec.specifier)
        merged.typeName = strongerSpec.typeName ?? weakerSpec.typeName
        merged.fieldNames = mergedFieldNames(weaker: weakerSpec.fieldNames, stronger: strongerSpec.fieldNames)
        var mergedFields = weakerSpec.fields
        for (fieldName, strongerValue) in strongerSpec.fields {
            if let weakerValue = mergedFields[fieldName] {
                mergedFields[fieldName] = try mergedFieldValue(weaker: weakerValue, stronger: strongerValue)
            } else {
                mergedFields[fieldName] = strongerValue
            }
        }
        merged.fields = mergedFields
        return merged
    }

    private static func mergedFieldValue(
        weaker: USDLayerFieldValue,
        stronger: USDLayerFieldValue
    ) throws -> USDLayerFieldValue {
        switch (weaker, stronger) {
        case (.dictionary(let weakerValues), .dictionary(let strongerValues)):
            return .dictionary(mergedDictionary(weaker: weakerValues, stronger: strongerValues))
        case (.tokenListOperation(let weakerOperation), .tokenListOperation(let strongerOperation)):
            return .tokenListOperation(try composedListOperation(weaker: weakerOperation, stronger: strongerOperation))
        case (.stringListOperation(let weakerOperation), .stringListOperation(let strongerOperation)):
            return .stringListOperation(try composedListOperation(weaker: weakerOperation, stronger: strongerOperation))
        case (.pathListOperation(let weakerOperation), .pathListOperation(let strongerOperation)):
            return .pathListOperation(try composedListOperation(weaker: weakerOperation, stronger: strongerOperation))
        case (.referenceListOperation(let weakerOperation), .referenceListOperation(let strongerOperation)):
            return .referenceListOperation(try composedListOperation(weaker: weakerOperation, stronger: strongerOperation))
        case (.payloadListOperation(let weakerOperation), .payloadListOperation(let strongerOperation)):
            return .payloadListOperation(try composedListOperation(weaker: weakerOperation, stronger: strongerOperation))
        default:
            return stronger
        }
    }

    /// Merges dictionary-valued fields recursively: the stronger value wins per key, and
    /// nested dictionaries merge key by key, matching upstream `VtDictionaryOverRecursive`.
    private static func mergedDictionary(
        weaker: [String: SdfFieldValue],
        stronger: [String: SdfFieldValue]
    ) -> [String: SdfFieldValue] {
        var merged = weaker
        for (key, strongerValue) in stronger {
            if case .dictionary(let strongerChild) = strongerValue,
               case .dictionary(let weakerChild)? = merged[key] {
                merged[key] = .dictionary(mergedDictionary(weaker: weakerChild, stronger: strongerChild))
            } else {
                merged[key] = strongerValue
            }
        }
        return merged
    }

    /// Composes two list operations so that applying the result equals applying the
    /// weaker operation and then the stronger one, matching upstream
    /// `SdfListOp::ApplyOperations(const SdfListOp &inner)`. Compositions involving
    /// added or ordered items cannot be represented as a single list operation.
    private static func composedListOperation<Item: Sendable & Equatable & Hashable>(
        weaker: SdfListOperation<Item>,
        stronger: SdfListOperation<Item>
    ) throws -> SdfListOperation<Item> {
        if stronger.isExplicit {
            return stronger
        }
        guard stronger.addedItems.isEmpty, stronger.orderedItems.isEmpty else {
            throw USDError.unsupportedFeature(
                "USDStage composition cannot compose list operations whose stronger operation uses added or ordered items."
            )
        }
        if weaker.isExplicit {
            return SdfListOperation(
                isExplicit: true,
                explicitItems: stronger.applying(to: weaker.explicitItems)
            )
        }
        guard weaker.addedItems.isEmpty, weaker.orderedItems.isEmpty else {
            throw USDError.unsupportedFeature(
                "USDStage composition cannot compose list operations whose weaker operation uses added or ordered items."
            )
        }
        var deletedItems = SdfListOperation<Item>.uniqueItems(weaker.deletedItems)
        var prependedItems = SdfListOperation<Item>.uniqueItems(weaker.prependedItems)
        var appendedItems = SdfListOperation<Item>.uniqueItems(weaker.appendedItems)
        for item in stronger.deletedItems {
            prependedItems.removeAll { $0 == item }
            appendedItems.removeAll { $0 == item }
            if !deletedItems.contains(item) {
                deletedItems.append(item)
            }
        }
        let strongerPrepended = SdfListOperation<Item>.uniqueItems(stronger.prependedItems)
        for item in strongerPrepended {
            deletedItems.removeAll { $0 == item }
            prependedItems.removeAll { $0 == item }
            appendedItems.removeAll { $0 == item }
        }
        prependedItems = strongerPrepended + prependedItems
        let strongerAppended = SdfListOperation<Item>.uniqueItems(stronger.appendedItems)
        for item in strongerAppended {
            deletedItems.removeAll { $0 == item }
            prependedItems.removeAll { $0 == item }
            appendedItems.removeAll { $0 == item }
        }
        appendedItems.append(contentsOf: strongerAppended)
        return SdfListOperation(
            prependedItems: prependedItems,
            appendedItems: appendedItems,
            deletedItems: deletedItems
        )
    }

    private static func composedSpecifier(weaker: SdfSpecifier?, stronger: SdfSpecifier?) -> SdfSpecifier? {
        switch (weaker, stronger) {
        case (_, .def?):
            return .def
        case (_, .class?):
            return .class
        case (_, .unknown?):
            return stronger
        case (.def?, .over?):
            return .def
        case (.class?, .over?):
            return .class
        case (_, .over?):
            return .over
        case (let weaker, nil):
            return weaker
        }
    }

    private static func mergedFieldNames(weaker: [String], stronger: [String]) -> [String] {
        var names = stronger
        var seenNames = Set(stronger)
        for fieldName in weaker where seenNames.insert(fieldName).inserted {
            names.append(fieldName)
        }
        return names
    }
}
