import Foundation

struct USDStageCompositionResolver: Sendable {
    var rootLayer: USDALayer
    var rootIdentifier: String
    var provider: any USDLayerProvider
    var missingDefaultPrimPolicy: USDCompositionMissingDefaultPrimPolicy = .fail

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
            guard let payloadLayer = try flattenedReferencedLayer(
                arc: arc,
                ancestorKeys: descendantAncestorKeys,
                cache: cache
            ) else {
                continue
            }
            try accumulator.merge(strongerLayer: payloadLayer, preservingWorldTransforms: true)
        }
        for arc in arcs.references.reversed() {
            guard let referenceLayer = try flattenedReferencedLayer(
                arc: arc,
                ancestorKeys: descendantAncestorKeys,
                cache: cache
            ) else {
                continue
            }
            try accumulator.merge(strongerLayer: referenceLayer, preservingWorldTransforms: true)
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
    ) throws -> USDALayer? {
        let targetIdentifier: String
        let targetLayer: USDALayer
        if arc.assetPath.isEmpty {
            targetIdentifier = arc.stackRootIdentifier
            targetLayer = arc.stackRootLayer
        } else {
            targetIdentifier = try resolvedLayerIdentifier(arc.assetPath, referencedFrom: arc.sourceIdentifier)
            targetLayer = try requireLayer(resolvedIdentifier: targetIdentifier, cache: cache)
        }

        guard let effectiveTargetPrimPath = try self.effectiveTargetPrimPath(
            authoredTargetPrimPath: arc.targetPrimPath,
            targetLayer: targetLayer,
            targetIdentifier: targetIdentifier
        ) else {
            return nil
        }
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
        let targetParentTransform = composedTargetParentTransform(
            for: effectiveTargetPrimPath,
            in: flattenedTargetLayer
        )
        let rewrittenLayer = try rewrite(
            flattenedTargetLayer,
            sourceTargetPrimPath: effectiveTargetPrimPath,
            sitePrimPath: arc.sitePrimPath,
            targetParentTransform: targetParentTransform
        )
        return try applying(arc.layerOffset, to: rewrittenLayer)
    }

    private func composedTargetParentTransform(
        for targetPrimPath: String,
        in layer: USDALayer
    ) -> USDTransformMatrix4x4 {
        if layer.resetXformStackPrimPaths.contains(targetPrimPath) {
            return .identity
        }
        return parentPrimPath(targetPrimPath)
            .flatMap { layer.primTransforms[$0] }
            ?? .identity
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
    ) throws -> String? {
        if let authoredTargetPrimPath, !authoredTargetPrimPath.isEmpty, authoredTargetPrimPath != "/" {
            return authoredTargetPrimPath
        }
        guard let defaultPrim = targetLayer.defaultPrim, !defaultPrim.isEmpty else {
            if missingDefaultPrimPolicy == .skipArc {
                return nil
            }
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
        sitePrimPath: String,
        targetParentTransform: USDTransformMatrix4x4
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

        let inverseTargetParentTransform = try targetParentTransform.inverted()
        var rewrittenTransforms: [String: USDTransformMatrix4x4] = [:]
        for (path, transform) in layer.primTransforms {
            guard let rewrittenPath = rewrittenPath(
                path,
                sourceTargetPrimPath: sourceTargetPrimPath,
                sitePrimPath: sitePrimPath
            ) else {
                continue
            }
            rewrittenTransforms[rewrittenPath] = try transform.concatenating(inverseTargetParentTransform)
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

    private func parentPrimPath(_ path: String) -> String? {
        guard path != "/", let slashIndex = path.lastIndex(of: "/") else {
            return nil
        }
        if slashIndex == path.startIndex {
            return nil
        }
        return String(path[..<slashIndex])
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
            switch timeSamplesValue {
            case .authored(let timeSamplesText):
                adjustedSpec.fields["timeSamples"] = .authored(
                    try remappedTimeSamplesText(timeSamplesText, applying: layerOffset, at: spec.path)
                )
            case .timeSamples(let samples):
                adjustedSpec.fields["timeSamples"] = .timeSamples(
                    try remappedTimeSamples(samples, applying: layerOffset, at: spec.path)
                )
            default:
                throw USDError.unsupportedFeature(
                    "USDStage composition cannot apply a layer offset to unsupported timeSamples at \(spec.path)."
                )
            }
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

    private func remappedTimeSamples(
        _ samples: [SdfTimeSample],
        applying layerOffset: SdfLayerOffset,
        at path: String
    ) throws -> [SdfTimeSample] {
        guard layerOffset.scale != 0 else {
            throw USDError.invalidData(
                "USDStage composition cannot remap timeSamples at \(path) with a zero layer offset scale."
            )
        }
        return try samples.map { sample in
            SdfTimeSample(
                timeCode: try remappedTimeCode(sample.timeCode, applying: layerOffset, at: path),
                value: sample.value
            )
        }
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
            let remappedTimeCode = try formattedTimeCode(
                remappedTimeCode(entry.timeCode, applying: layerOffset, at: path),
                at: path
            )
            return "    \(remappedTimeCode): \(entry.value)"
        }
        return "{\n\(lines.joined(separator: ",\n"))\n}"
    }

    private func remappedTimeCode(_ timeCode: Double, applying layerOffset: SdfLayerOffset, at path: String) throws -> Double {
        let remapped = layerOffset.stageTime(forLayerTime: timeCode)
        guard remapped.isFinite else {
            throw USDError.invalidData(
                "USDStage composition produced a non-finite remapped timeCode at \(path)."
            )
        }
        return remapped
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

private struct USDStageXformAuthorship: Sendable, Equatable {
    var authorsOrder = false
    var authorsOperation = false
    var localSiteTransform: USDTransformMatrix4x4?
}

/// Accumulates layers from weakest to strongest, merging each stronger layer over the
/// accumulated result. Spec lookup stays O(1) through the layer's own path index.
private struct USDStageLayerAccumulator {
    private(set) var layer = USDALayer()
    private var preservedLocalTransforms: [String: USDTransformMatrix4x4] = [:]
    private var locallyAuthoredXformOpinions: [String: USDStageXformAuthorship] = [:]

    mutating func merge(strongerLayer: USDALayer, preservingWorldTransforms: Bool = false) throws {
        layer.defaultPrim = strongerLayer.defaultPrim ?? layer.defaultPrim
        layer.metersPerUnit = strongerLayer.metersPerUnit ?? layer.metersPerUnit
        layer.upAxis = strongerLayer.upAxis ?? layer.upAxis
        if !preservingWorldTransforms {
            try mergeLocallyAuthoredXformOpinions(from: strongerLayer)
        }
        for spec in strongerLayer.specs {
            try merge(strongerSpec: spec)
        }
        if preservingWorldTransforms {
            try mergePreservedLocalTransforms(from: strongerLayer)
        }
        layer.resetXformStackPrimPaths = try Self.resetXformStackPrimPaths(in: layer)
        layer.primTransforms = try Self.worldTransforms(
            in: layer,
            preservedLocalTransforms: preservedLocalTransforms,
            locallyAuthoredXformOpinions: locallyAuthoredXformOpinions,
            resetXformStackPrimPaths: layer.resetXformStackPrimPaths
        )
    }

    private mutating func mergePreservedLocalTransforms(from strongerLayer: USDALayer) throws {
        let strongerTransforms = try Self.localTransformsFromWorldCache(in: strongerLayer)
        for (path, transform) in strongerTransforms {
            // Field merging already resolves arc strength; the sidecar keeps only
            // the strongest preserved transform for later local-site composition.
            preservedLocalTransforms[path] = transform
        }
    }

    private mutating func mergeLocallyAuthoredXformOpinions(from strongerLayer: USDALayer) throws {
        var opinions = Self.authoredXformOpinions(in: strongerLayer)
        for (path, opinion) in opinions where opinion.authorsOrder {
            opinions[path]?.localSiteTransform = try Self.localTransform(at: path, in: strongerLayer)
        }
        for (path, opinion) in opinions {
            locallyAuthoredXformOpinions[path] = opinion
        }
    }

    private static func localTransformsFromWorldCache(in layer: USDALayer) throws -> [String: USDTransformMatrix4x4] {
        var transforms: [String: USDTransformMatrix4x4] = [:]
        for path in layer.primTransforms.keys.sorted(by: compareNamespaceDepthThenPath) {
            guard let worldTransform = layer.primTransforms[path] else {
                continue
            }
            if layer.resetXformStackPrimPaths.contains(path) {
                transforms[path] = worldTransform
                continue
            }
            guard let parentPath = parentPrimPath(path),
                  let parentWorldTransform = layer.primTransforms[parentPath] else {
                transforms[path] = worldTransform
                continue
            }
            transforms[path] = try worldTransform.concatenating(parentWorldTransform.inverted())
        }
        return transforms
    }

    private static func worldTransforms(
        in layer: USDALayer,
        preservedLocalTransforms: [String: USDTransformMatrix4x4],
        locallyAuthoredXformOpinions: [String: USDStageXformAuthorship],
        resetXformStackPrimPaths: Set<String>
    ) throws -> [String: USDTransformMatrix4x4] {
        var worldTransforms: [String: USDTransformMatrix4x4] = [:]
        let primPaths = layer.specs
            .filter { $0.specType == .prim }
            .map(\.path)
            .sorted(by: compareNamespaceDepthThenPath)
        for path in primPaths {
            let mergedLocalTransform = try localTransform(at: path, in: layer)
            let localMatrix: USDTransformMatrix4x4
            if let preservedLocalTransform = preservedLocalTransforms[path] {
                if let opinion = locallyAuthoredXformOpinions[path], opinion.authorsOrder {
                    localMatrix = try preservedLocalTransform.concatenating(
                        opinion.localSiteTransform ?? .identity
                    )
                } else if let opinion = locallyAuthoredXformOpinions[path], opinion.authorsOperation {
                    localMatrix = mergedLocalTransform
                } else {
                    localMatrix = preservedLocalTransform
                }
            } else {
                localMatrix = mergedLocalTransform
            }
            if resetXformStackPrimPaths.contains(path) {
                worldTransforms[path] = localMatrix
                continue
            }
            guard let parentPath = parentPrimPath(path),
                  let parentTransform = worldTransforms[parentPath] else {
                worldTransforms[path] = localMatrix
                continue
            }
            worldTransforms[path] = try localMatrix.concatenating(parentTransform)
        }
        return worldTransforms
    }

    private static func authoredXformOpinions(in layer: USDALayer) -> [String: USDStageXformAuthorship] {
        var opinions: [String: USDStageXformAuthorship] = [:]
        for spec in layer.specs where spec.specType == .attribute {
            guard let propertyPath = propertyPathComponents(spec.path) else {
                continue
            }
            if propertyPath.propertyName == "xformOpOrder" {
                opinions[propertyPath.primPath, default: USDStageXformAuthorship()].authorsOrder = true
            } else if propertyPath.propertyName.hasPrefix("xformOp:") {
                opinions[propertyPath.primPath, default: USDStageXformAuthorship()].authorsOperation = true
            }
        }
        return opinions
    }

    private static func propertyPathComponents(_ path: String) -> (primPath: String, propertyName: String)? {
        guard let separator = path.firstIndex(of: "."), separator != path.startIndex else {
            return nil
        }
        let propertyStart = path.index(after: separator)
        guard propertyStart < path.endIndex else {
            return nil
        }
        return (String(path[..<separator]), String(path[propertyStart...]))
    }

    private static func localTransform(at primPath: String, in layer: USDALayer) throws -> USDTransformMatrix4x4 {
        guard let xformOpOrder = try xformOpOrderTokens(at: primPath, in: layer) else {
            return .identity
        }
        var localMatrix = USDTransformMatrix4x4.identity
        for opName in xformOpOrder.reversed() {
            if opName == "!resetXformStack!" {
                break
            }
            let orderedOp = orderedXformOperationName(from: opName)
            guard let opSpec = layer.spec(at: "\(primPath).\(orderedOp.attributeName)") else {
                continue
            }
            let opTransform = try transform(forXformOp: orderedOp.attributeName, spec: opSpec)
            let effectiveTransform = orderedOp.isInverted ? try opTransform.inverted() : opTransform
            localMatrix = try localMatrix.concatenating(effectiveTransform)
        }
        return localMatrix
    }

    private static func orderedXformOperationName(from opName: String) -> (attributeName: String, isInverted: Bool) {
        let prefix = "!invert!"
        guard opName.hasPrefix(prefix) else {
            return (opName, false)
        }
        var attributeName = String(opName.dropFirst(prefix.count))
        if attributeName.hasPrefix(":") {
            attributeName.removeFirst()
        }
        return (attributeName, true)
    }

    private static func transform(forXformOp opName: String, spec: USDLayerSpec) throws -> USDTransformMatrix4x4 {
        guard let operationType = xformOperationType(from: opName) else {
            throw USDError.invalidData("USDStage composition xform op \(opName) is malformed.")
        }
        switch operationType {
        case "translate":
            return .translation(try requiredVector3Value(forXformOp: opName, spec: spec))
        case "translateX":
            return .translation(USDTransformVector3D(
                x: try requiredScalarValue(forXformOp: opName, spec: spec),
                y: 0,
                z: 0
            ))
        case "translateY":
            return .translation(USDTransformVector3D(
                x: 0,
                y: try requiredScalarValue(forXformOp: opName, spec: spec),
                z: 0
            ))
        case "translateZ":
            return .translation(USDTransformVector3D(
                x: 0,
                y: 0,
                z: try requiredScalarValue(forXformOp: opName, spec: spec)
            ))
        case "scale":
            return .scale(try requiredVector3Value(forXformOp: opName, spec: spec))
        case "scaleX":
            return .scale(USDTransformVector3D(
                x: try requiredScalarValue(forXformOp: opName, spec: spec),
                y: 1,
                z: 1
            ))
        case "scaleY":
            return .scale(USDTransformVector3D(
                x: 1,
                y: try requiredScalarValue(forXformOp: opName, spec: spec),
                z: 1
            ))
        case "scaleZ":
            return .scale(USDTransformVector3D(
                x: 1,
                y: 1,
                z: try requiredScalarValue(forXformOp: opName, spec: spec)
            ))
        case "rotateX":
            return try .rotationX(angleInDegrees: requiredScalarValue(forXformOp: opName, spec: spec))
        case "rotateY":
            return try .rotationY(angleInDegrees: requiredScalarValue(forXformOp: opName, spec: spec))
        case "rotateZ":
            return try .rotationZ(angleInDegrees: requiredScalarValue(forXformOp: opName, spec: spec))
        case "rotateXYZ", "rotateXZY", "rotateYXZ", "rotateYZX", "rotateZXY", "rotateZYX":
            let order = String(operationType.dropFirst("rotate".count))
            return try .eulerRotation(order: order, anglesInDegrees: requiredVector3Value(forXformOp: opName, spec: spec))
        case "orient":
            return try requiredQuaternionValue(forXformOp: opName, spec: spec).rotationMatrix()
        case "transform":
            return try requiredMatrix4x4Value(forXformOp: opName, spec: spec)
        default:
            throw USDError.unsupportedFeature("USDStage composition xform op \(operationType) is not supported yet.")
        }
    }

    private static func xformOperationType(from opName: String) -> String? {
        let prefix = "xformOp:"
        guard opName.hasPrefix(prefix) else {
            return nil
        }
        let suffixStart = opName.index(opName.startIndex, offsetBy: prefix.count)
        return opName[suffixStart...].split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    private static func requiredScalarValue(forXformOp opName: String, spec: USDLayerSpec) throws -> Double {
        guard let field = spec.fields["default"] else {
            throw USDError.missingRequiredField(opName)
        }
        return try scalarValue(from: field, name: opName)
    }

    private static func requiredVector3Value(forXformOp opName: String, spec: USDLayerSpec) throws -> USDTransformVector3D {
        guard let field = spec.fields["default"] else {
            throw USDError.missingRequiredField(opName)
        }
        return try vector3Value(from: field, name: opName)
    }

    private static func requiredQuaternionValue(forXformOp opName: String, spec: USDLayerSpec) throws -> USDTransformQuaternion {
        guard let field = spec.fields["default"] else {
            throw USDError.missingRequiredField(opName)
        }
        let values = try tupleValues(from: field, expectedCount: 4, name: opName)
        return USDTransformQuaternion(
            real: values[0],
            imaginaryX: values[1],
            imaginaryY: values[2],
            imaginaryZ: values[3]
        )
    }

    private static func requiredMatrix4x4Value(forXformOp opName: String, spec: USDLayerSpec) throws -> USDTransformMatrix4x4 {
        guard let field = spec.fields["default"] else {
            throw USDError.missingRequiredField(opName)
        }
        return USDTransformMatrix4x4(values: try matrix4x4Values(from: field, name: opName))
    }

    private static func scalarValue(from field: USDLayerFieldValue, name: String) throws -> Double {
        switch field {
        case .authored(let text):
            let trimmedText = removingLineComments(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(trimmedText), value.isFinite else {
                throw USDError.invalidData("USDStage composition \(name) contains a non-finite scalar.")
            }
            return value
        default:
            throw USDError.unsupportedFeature("USDStage composition cannot read a typed scalar xform op field yet.")
        }
    }

    private static func vector3Value(from field: USDLayerFieldValue, name: String) throws -> USDTransformVector3D {
        let values = try tupleValues(from: field, expectedCount: 3, name: name)
        return USDTransformVector3D(x: values[0], y: values[1], z: values[2])
    }

    private static func tupleValues(
        from field: USDLayerFieldValue,
        expectedCount: Int,
        name: String
    ) throws -> [Double] {
        switch field {
        case .authored(let text):
            return try tupleValues(from: text, expectedCount: expectedCount, name: name)
        default:
            throw USDError.unsupportedFeature("USDStage composition cannot read a typed tuple xform op field yet.")
        }
    }

    private static func tupleValues(
        from text: String,
        expectedCount: Int,
        name: String
    ) throws -> [Double] {
        let body = try parenthesizedBody(text, name: name)
        let values = try numericValues(in: body, name: name)
        guard values.count == expectedCount else {
            throw USDError.invalidData("USDStage composition \(name) tuple contains \(values.count) values.")
        }
        return values
    }

    private static func matrix4x4Values(from field: USDLayerFieldValue, name: String) throws -> [Double] {
        switch field {
        case .authored(let text):
            return try matrix4x4Values(from: text, name: name)
        default:
            throw USDError.unsupportedFeature("USDStage composition cannot read a typed matrix xform op field yet.")
        }
    }

    private static func matrix4x4Values(from text: String, name: String) throws -> [Double] {
        let body = try parenthesizedBody(text, name: name)
        guard body.contains("(") else {
            let values = try numericValues(in: body, name: name)
            guard values.count == 16 else {
                throw USDError.invalidData("USDStage composition \(name) matrix contains \(values.count) values.")
            }
            return values
        }
        var cursor = body.startIndex
        var rows: [[Double]] = []
        while true {
            skipSeparators(in: body, index: &cursor)
            guard cursor < body.endIndex else {
                break
            }
            guard body[cursor] == "(" else {
                throw USDError.invalidData("USDStage composition \(name) matrix contains unexpected content.")
            }
            let close = try matchingDelimiter(in: body, from: cursor, open: "(", close: ")")
            let rowBody = String(body[body.index(after: cursor)..<close])
            let row = try numericValues(in: rowBody, name: name)
            guard row.count == 4 else {
                throw USDError.invalidData("USDStage composition \(name) matrix row contains \(row.count) values.")
            }
            rows.append(row)
            cursor = body.index(after: close)
        }
        guard rows.count == 4 else {
            throw USDError.invalidData("USDStage composition \(name) matrix contains \(rows.count) rows.")
        }
        return rows.flatMap { $0 }
    }

    private static func parenthesizedBody(_ text: String, name: String) throws -> String {
        var cursor = text.startIndex
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "(" else {
            throw USDError.invalidData("USDStage composition \(name) is missing an opening parenthesis.")
        }
        let close = try matchingDelimiter(in: text, from: cursor, open: "(", close: ")")
        var trailing = text.index(after: close)
        skipWhitespace(in: text, index: &trailing)
        guard trailing == text.endIndex else {
            throw USDError.invalidData("USDStage composition \(name) contains trailing tuple content.")
        }
        return String(text[text.index(after: cursor)..<close])
    }

    private static func numericValues(in text: String, name: String) throws -> [Double] {
        let tokens = removingLineComments(from: text).split { $0 == "," || $0.isWhitespace || $0.isNewline }
        return try tokens.map { token in
            guard let value = Double(token), value.isFinite else {
                throw USDError.invalidData("USDStage composition \(name) contains a non-finite number.")
            }
            return value
        }
    }

    private static func resetXformStackPrimPaths(in layer: USDALayer) throws -> Set<String> {
        var paths: Set<String> = []
        for spec in layer.specs where spec.specType == .prim {
            guard let tokens = try xformOpOrderTokens(at: spec.path, in: layer),
                  tokens.contains("!resetXformStack!") else {
                continue
            }
            paths.insert(spec.path)
        }
        return paths
    }

    private static func xformOpOrderTokens(at primPath: String, in layer: USDALayer) throws -> [String]? {
        guard let spec = layer.spec(at: "\(primPath).xformOpOrder"),
              let field = spec.fields["default"] else {
            return nil
        }
        return try tokenArray(from: field)
    }

    private static func tokenArray(from field: USDLayerFieldValue) throws -> [String] {
        switch field {
        case .authored(let text):
            return try authoredTokenArray(text)
        default:
            throw USDError.unsupportedFeature("USDStage composition cannot read a typed xformOpOrder field yet.")
        }
    }

    private static func authoredTokenArray(_ text: String) throws -> [String] {
        var cursor = text.startIndex
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "[" else {
            throw USDError.invalidData("USDStage composition xformOpOrder must be a token array.")
        }
        cursor = text.index(after: cursor)
        var tokens: [String] = []
        while true {
            skipWhitespace(in: text, index: &cursor)
            guard cursor < text.endIndex else {
                throw USDError.invalidData("USDStage composition xformOpOrder is unterminated.")
            }
            if text[cursor] == "]" {
                cursor = text.index(after: cursor)
                skipWhitespace(in: text, index: &cursor)
                guard cursor == text.endIndex else {
                    throw USDError.invalidData("USDStage composition xformOpOrder contains trailing content.")
                }
                return tokens
            }
            tokens.append(try authoredStringToken(in: text, index: &cursor))
            skipWhitespace(in: text, index: &cursor)
            if cursor < text.endIndex, text[cursor] == "," {
                cursor = text.index(after: cursor)
            }
        }
    }

    private static func authoredStringToken(in text: String, index: inout String.Index) throws -> String {
        guard index < text.endIndex else {
            throw USDError.invalidData("USDStage composition xformOpOrder token is missing.")
        }
        if text[index] == "\"" || text[index] == "'" {
            return try quotedString(in: text, index: &index)
        }
        let start = index
        while index < text.endIndex, text[index] != "," && text[index] != "]" && !text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard start < index else {
            throw USDError.invalidData("USDStage composition xformOpOrder token is empty.")
        }
        return String(text[start..<index])
    }

    private static func quotedString(in text: String, index: inout String.Index) throws -> String {
        let quote = text[index]
        index = text.index(after: index)
        var value = ""
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                index = text.index(after: index)
                return value
            }
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else {
                    throw USDError.invalidData("USDStage composition xformOpOrder escape is unterminated.")
                }
            }
            value.append(text[index])
            index = text.index(after: index)
        }
        throw USDError.invalidData("USDStage composition xformOpOrder string is unterminated.")
    }

    private static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            if text[index] == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            break
        }
    }

    private static func skipSeparators(in text: String, index: inout String.Index) {
        while index < text.endIndex {
            if text[index].isWhitespace || text[index] == "," {
                index = text.index(after: index)
                continue
            }
            if text[index] == "#" {
                skipLineComment(in: text, index: &index)
                continue
            }
            break
        }
    }

    private static func matchingDelimiter(
        in text: String,
        from openIndex: String.Index,
        open: Character,
        close: Character
    ) throws -> String.Index {
        var depth = 0
        var cursor = openIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            if character == "\"" || character == "'" {
                var quotedCursor = cursor
                _ = try quotedString(in: text, index: &quotedCursor)
                cursor = quotedCursor
                continue
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor = text.index(after: cursor)
        }
        throw USDError.invalidData("USDStage composition value delimiter is unterminated.")
    }

    private static func skipLineComment(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index] != "\n", text[index] != "\r" {
            index = text.index(after: index)
        }
    }

    private static func removingLineComments(from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "#" {
                skipLineComment(in: text, index: &cursor)
                continue
            }
            result.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return result
    }

    private static func parentPrimPath(_ path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/"), slash != path.startIndex else {
            return nil
        }
        return String(path[..<slash])
    }

    private static func compareNamespaceDepthThenPath(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = namespaceDepth(of: lhs)
        let rhsDepth = namespaceDepth(of: rhs)
        guard lhsDepth == rhsDepth else {
            return lhsDepth < rhsDepth
        }
        return lhs < rhs
    }

    private static func namespaceDepth(of path: String) -> Int {
        path.split(separator: "/").count
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
