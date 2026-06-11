import Foundation
import OpenUSD
import OpenUSDC

public struct USDZReader: USDSceneReader {
    public static let fileSignature: [UInt8] = [0x50, 0x4b]

    private let textReader: USDAReader

    public init(textReader: USDAReader = USDAReader()) {
        self.textReader = textReader
    }

    public func read(from data: Data) throws -> USDScene {
        try read(from: data, options: .default)
    }

    public func read(from data: Data, options: USDReadingOptions) throws -> USDScene {
        let archive = try readArchive(from: data)
        let defaultLayerPath = try defaultLayerPath(in: archive)
        return try readResolvedScene(defaultLayerPath: defaultLayerPath, in: archive, options: options)
    }

    public func read(from data: Data, rootLayerPath: String) throws -> USDScene {
        try read(from: data, rootLayerPath: rootLayerPath, options: .default)
    }

    public func read(from data: Data, rootLayerPath: String, options: USDReadingOptions) throws -> USDScene {
        let archive = try readArchive(from: data)
        let resolvedRootLayerPath = try resolveRootLayerPath(rootLayerPath, in: archive)
        return try readResolvedScene(defaultLayerPath: resolvedRootLayerPath, in: archive, options: options)
    }

    public func readLayerGraph(from data: Data) throws -> USDZLayerGraph {
        let archive = try readArchive(from: data)
        let defaultLayerPath = try defaultLayerPath(in: archive)
        return try readLayerGraph(defaultLayerPath: defaultLayerPath, in: archive)
    }

    public func readLayerGraph(from data: Data, rootLayerPath: String) throws -> USDZLayerGraph {
        let archive = try readArchive(from: data)
        let resolvedRootLayerPath = try resolveRootLayerPath(rootLayerPath, in: archive)
        return try readLayerGraph(defaultLayerPath: resolvedRootLayerPath, in: archive)
    }

    private func readLayerGraph(defaultLayerPath: String, in archive: USDZArchive) throws -> USDZLayerGraph {
        let layers = try readResolvedLayers(defaultLayerPath: defaultLayerPath, in: archive)
        return USDZLayerGraph(
            rootPath: defaultLayerPath,
            layers: layers.map { layer in
                USDZLayerGraph.Layer(
                    path: layer.path,
                    defaultPrim: layer.defaultPrim,
                    metersPerUnit: layer.metersPerUnit,
                    upAxis: layer.upAxis,
                    composition: layer.composition,
                    hasScene: layer.scene != nil
                )
            }
        )
    }

    private func readArchive(from data: Data) throws -> USDZArchive {
        guard data.starts(with: Self.fileSignature) else {
            throw USDError.invalidData("USDZ data is missing the ZIP signature.")
        }
        return try USDZArchive(data: data)
    }

    private func defaultLayerPath(in archive: USDZArchive) throws -> String {
        guard let defaultLayer = archive.defaultLayer else {
            throw USDError.invalidData("USDZ package contains no entries.")
        }
        if defaultLayer.isUSDLayer {
            return defaultLayer.path
        }
        if defaultLayer.fileExtension == "usdz" {
            let nestedArchive = try USDZArchive(data: defaultLayer.data)
            guard let nestedDefaultLayer = nestedArchive.defaultLayer,
                  nestedDefaultLayer.isUSDLayer else {
                throw USDError.unsupportedFeature(
                    "USDZ nested default package \(defaultLayer.path) must contain a USD default layer."
                )
            }
            return "\(defaultLayer.path)[\(nestedDefaultLayer.path)]"
        }
        throw USDError.unsupportedFeature("USDZ default layer must be the first file and use a USD extension.")
    }

    private func resolveRootLayerPath(_ rootLayerPath: String, in archive: USDZArchive) throws -> String {
        let layerPath = try USDZLayerPath.parse(rootLayerPath)
        guard !layerPath.entryPaths.isEmpty else {
            throw USDError.invalidData("USDZ layer path is empty.")
        }
        return try resolveRootLayerPath(entryPaths: layerPath.entryPaths, in: archive).stringValue
    }

    private func resolveRootLayerPath(entryPaths: [String], in archive: USDZArchive) throws -> USDZLayerPath {
        var currentArchive = archive
        var resolvedEntryPaths: [String] = []
        for (index, entryPath) in entryPaths.enumerated() {
            guard let entry = currentArchive.entry(at: entryPath) else {
                throw USDError.invalidData("USDZ package is missing entry \(entryPath).")
            }

            resolvedEntryPaths.append(entry.path)
            let isLastEntry = index == entryPaths.count - 1
            if isLastEntry {
                if entry.isUSDLayer {
                    return USDZLayerPath(entryPaths: resolvedEntryPaths)
                }
                guard entry.fileExtension == "usdz" else {
                    throw USDError.unsupportedFeature("USDZ entry \(entry.path) is not a USD layer.")
                }
                let nestedArchive = try USDZArchive(data: entry.data)
                let nestedDefaultLayerPath = try defaultLayerPath(in: nestedArchive)
                let nestedDefaultEntryPaths = try USDZLayerPath.parse(nestedDefaultLayerPath).entryPaths
                return USDZLayerPath(
                    entryPaths: resolvedEntryPaths + nestedDefaultEntryPaths
                )
            }

            guard entry.fileExtension == "usdz" else {
                throw USDError.unsupportedFeature("USDZ entry \(entry.path) is not a nested USDZ package.")
            }
            currentArchive = try USDZArchive(data: entry.data)
        }

        throw USDError.invalidData("USDZ layer path is empty.")
    }

    private func readResolvedScene(
        defaultLayerPath: String,
        in archive: USDZArchive,
        options: USDReadingOptions
    ) throws -> USDScene {
        let resolvedLayerInstances = try readResolvedLayerInstances(
            defaultLayerPath: defaultLayerPath,
            in: archive,
            options: options
        )
        let meshes = try resolvedLayerInstances.flatMap { layerInstance in
            try materializedMeshes(in: layerInstance)
        }
        guard !meshes.isEmpty else {
            throw USDError.invalidData("USDZ scene contains no Mesh prims.")
        }
        let rootLayer = resolvedLayerInstances.first?.layer
        let firstScene = resolvedLayerInstances.compactMap(\.layer.scene).first
        return USDScene(
            defaultPrim: rootLayer?.defaultPrim ?? rootLayer?.scene?.defaultPrim ?? firstScene?.defaultPrim,
            metersPerUnit: rootLayer?.metersPerUnit ?? rootLayer?.scene?.metersPerUnit ?? firstScene?.metersPerUnit ?? 1,
            upAxis: rootLayer?.upAxis ?? rootLayer?.scene?.upAxis ?? firstScene?.upAxis ?? .y,
            meshes: meshes
        )
    }

    private func readResolvedLayerInstances(
        defaultLayerPath: String,
        in archive: USDZArchive,
        options: USDReadingOptions
    ) throws -> [USDZResolvedLayerInstance] {
        var visitedLayerInstances: Set<USDZLayerInstanceKey> = []
        var pendingLayerInstances = [
            USDZPendingLayerInstance(
                layerPath: defaultLayerPath,
                sitePrimPath: nil as String?,
                siteTransform: .identity,
                targetPrimPath: nil as String?,
                layerOffset: .identity,
                ancestorKeys: []
            )
        ]
        var resolvedLayerInstances: [USDZResolvedLayerInstance] = []
        // The visited check below cannot run before parsing: the instance key
        // depends on the parsed layer's defaultPrim. Caching parsed layers
        // keeps repeatedly referenced layers from being re-parsed per instance.
        var parsedLayersByKey: [USDZLayerParseKey: USDZResolvedLayer] = [:]

        while let pendingLayerInstance = pendingLayerInstances.first {
            pendingLayerInstances.removeFirst()
            let layerReadingOptions = try layerOptions(
                from: options,
                applying: pendingLayerInstance.layerOffset
            )
            let parseKey = USDZLayerParseKey(
                layerPath: pendingLayerInstance.layerPath,
                options: layerReadingOptions
            )
            let layer: USDZResolvedLayer
            if let parsedLayer = parsedLayersByKey[parseKey] {
                layer = parsedLayer
            } else {
                layer = try readLayer(
                    at: pendingLayerInstance.layerPath,
                    in: archive,
                    options: layerReadingOptions
                )
                parsedLayersByKey[parseKey] = layer
            }
            let effectiveTargetPrimPath = effectiveTargetPrimPath(
                targetPrimPath: pendingLayerInstance.targetPrimPath,
                sitePrimPath: pendingLayerInstance.sitePrimPath,
                layer: layer
            )
            guard pendingLayerInstance.sitePrimPath == nil || effectiveTargetPrimPath != nil else {
                continue
            }
            let instanceKey = USDZLayerInstanceKey(
                layerPath: pendingLayerInstance.layerPath,
                sitePrimPath: pendingLayerInstance.sitePrimPath,
                targetPrimPath: effectiveTargetPrimPath
            )
            if pendingLayerInstance.ancestorKeys.contains(instanceKey) {
                throw USDError.invalidData("USDZ composition cycle detected.")
            }
            guard visitedLayerInstances.insert(instanceKey).inserted else {
                continue
            }
            var descendantAncestorKeys = pendingLayerInstance.ancestorKeys
            descendantAncestorKeys.insert(instanceKey)
            resolvedLayerInstances.append(USDZResolvedLayerInstance(
                layer: layer,
                sitePrimPath: pendingLayerInstance.sitePrimPath,
                siteTransform: pendingLayerInstance.siteTransform,
                targetPrimPath: effectiveTargetPrimPath,
                layerOffset: pendingLayerInstance.layerOffset
            ))
            for sublayer in layer.composition.sublayers {
                guard let resolvedLayerPath = try archive.resolveLayerPath(
                    for: sublayer.assetPath,
                    referencedFrom: pendingLayerInstance.layerPath
                ) else {
                    throw USDError.invalidData(
                        "USDZ package could not resolve asset \(sublayer.assetPath) from \(pendingLayerInstance.layerPath)."
                    )
                }
                pendingLayerInstances.append(USDZPendingLayerInstance(
                    layerPath: resolvedLayerPath,
                    sitePrimPath: pendingLayerInstance.sitePrimPath,
                    siteTransform: pendingLayerInstance.siteTransform,
                    targetPrimPath: effectiveTargetPrimPath,
                    layerOffset: pendingLayerInstance.layerOffset.concatenating(sublayer.layerOffset),
                    ancestorKeys: descendantAncestorKeys
                ))
            }
            for arc in layer.composition.references + layer.composition.payloads {
                guard let composedSitePrimPath = composedSitePrimPath(
                    for: arc.sitePrimPath,
                    sourceSitePrimPath: pendingLayerInstance.sitePrimPath,
                    sourceTargetPrimPath: effectiveTargetPrimPath
                ) else {
                    continue
                }
                let arcSiteTransform = arc.sitePrimPath.flatMap { layer.primTransforms[$0] } ?? .identity
                let composedSiteTransform = try arcSiteTransform.concatenating(pendingLayerInstance.siteTransform)
                guard let resolvedLayerPath = try resolvedLayerPath(
                    forArcAssetPath: arc.assetPath,
                    referencedFrom: pendingLayerInstance.layerPath,
                    in: archive
                ) else {
                    throw USDError.invalidData(
                        "USDZ package could not resolve asset \(arc.assetPath) from \(pendingLayerInstance.layerPath)."
                    )
                }
                pendingLayerInstances.append(USDZPendingLayerInstance(
                    layerPath: resolvedLayerPath,
                    sitePrimPath: composedSitePrimPath,
                    siteTransform: composedSiteTransform,
                    targetPrimPath: arc.targetPrimPath,
                    layerOffset: pendingLayerInstance.layerOffset.concatenating(arc.layerOffset),
                    ancestorKeys: descendantAncestorKeys
                ))
            }
        }
        return resolvedLayerInstances
    }

    private func materializedMeshes(in layerInstance: USDZResolvedLayerInstance) throws -> [USDMesh] {
        let targetPrimPath = effectiveTargetPrimPath(
            targetPrimPath: layerInstance.targetPrimPath,
            sitePrimPath: layerInstance.sitePrimPath,
            layer: layerInstance.layer
        )
        let meshes = filteredMeshes(in: layerInstance.layer.scene, matching: targetPrimPath)
        guard let sitePrimPath = layerInstance.sitePrimPath else {
            return meshes
        }
        guard let targetPrimPath else {
            return []
        }
        return try meshes.map { mesh in
            let sourceAncestorTransform = sourceAncestorTransform(
                forTargetPrimPath: targetPrimPath,
                in: layerInstance.layer
            )
            let rewriteTransform = try sourceAncestorTransform
                .inverted()
                .concatenating(layerInstance.siteTransform)
            return try rewriting(
                mesh,
                sourceTargetPrimPath: targetPrimPath,
                sitePrimPath: sitePrimPath,
                rewriteTransform: rewriteTransform
            )
        }
    }

    private func sourceAncestorTransform(
        forTargetPrimPath targetPrimPath: String,
        in layer: USDZResolvedLayer
    ) -> USDTransformMatrix4x4 {
        guard let parentPath = parentPrimPath(from: targetPrimPath),
              parentPath != "/" else {
            return .identity
        }
        guard !layer.resetXformStackPrimPaths.contains(targetPrimPath) else {
            return .identity
        }
        return layer.primTransforms[parentPath] ?? .identity
    }

    private func filteredMeshes(in scene: USDScene?, matching targetPrimPath: String?) -> [USDMesh] {
        guard let scene else {
            return []
        }
        guard let targetPrimPath, !targetPrimPath.isEmpty, targetPrimPath != "/" else {
            return scene.meshes
        }
        let descendantPrefix = "\(targetPrimPath)/"
        return scene.meshes.filter { mesh in
            guard let primPath = mesh.primPath else {
                return false
            }
            return primPath == targetPrimPath || primPath.hasPrefix(descendantPrefix)
        }
    }

    private func rewriting(
        _ mesh: USDMesh,
        sourceTargetPrimPath: String,
        sitePrimPath: String,
        rewriteTransform: USDTransformMatrix4x4
    ) throws -> USDMesh {
        var rewrittenMesh = mesh
        if let primPath = mesh.primPath,
           let rewrittenPrimPath = rewrittenPrimPath(
               primPath,
               replacing: sourceTargetPrimPath,
               with: sitePrimPath
           ) {
            rewrittenMesh.primPath = rewrittenPrimPath
            rewrittenMesh.name = lastPrimName(in: rewrittenPrimPath) ?? rewrittenMesh.name
        }
        rewrittenMesh.points = try rewrittenMesh.points.map { try rewriteTransform.transform($0) }
        rewrittenMesh.normals = try rewrittenMesh.normals.map { try rewriteTransform.transform(normal: $0) }
        rewrittenMesh.extent = try rewrittenExtent(rewrittenMesh.extent, applying: rewriteTransform)
        return rewrittenMesh
    }

    private func rewrittenExtent(
        _ extent: [USDPoint3D]?,
        applying transform: USDTransformMatrix4x4
    ) throws -> [USDPoint3D]? {
        guard let extent else {
            return nil
        }
        guard extent.count == 2 else {
            return try extent.map { try transform.transform($0) }
        }
        let minimum = extent[0]
        let maximum = extent[1]
        let corners = [
            USDPoint3D(x: minimum.x, y: minimum.y, z: minimum.z),
            USDPoint3D(x: maximum.x, y: minimum.y, z: minimum.z),
            USDPoint3D(x: minimum.x, y: maximum.y, z: minimum.z),
            USDPoint3D(x: minimum.x, y: minimum.y, z: maximum.z),
            USDPoint3D(x: maximum.x, y: maximum.y, z: minimum.z),
            USDPoint3D(x: maximum.x, y: minimum.y, z: maximum.z),
            USDPoint3D(x: minimum.x, y: maximum.y, z: maximum.z),
            USDPoint3D(x: maximum.x, y: maximum.y, z: maximum.z),
        ]
        let transformedCorners = try corners.map { try transform.transform($0) }
        let xs = transformedCorners.map(\.x)
        let ys = transformedCorners.map(\.y)
        let zs = transformedCorners.map(\.z)
        guard let minX = xs.min(),
              let minY = ys.min(),
              let minZ = zs.min(),
              let maxX = xs.max(),
              let maxY = ys.max(),
              let maxZ = zs.max() else {
            return nil
        }
        return [
            USDPoint3D(x: minX, y: minY, z: minZ),
            USDPoint3D(x: maxX, y: maxY, z: maxZ),
        ]
    }

    private func composedSitePrimPath(
        for arcSitePrimPath: String?,
        sourceSitePrimPath: String?,
        sourceTargetPrimPath: String?
    ) -> String? {
        guard let arcSitePrimPath else {
            return sourceSitePrimPath
        }
        guard let sourceSitePrimPath,
              let sourceTargetPrimPath else {
            return arcSitePrimPath
        }
        return rewrittenPrimPath(
            arcSitePrimPath,
            replacing: sourceTargetPrimPath,
            with: sourceSitePrimPath
        )
    }

    private func effectiveTargetPrimPath(
        targetPrimPath: String?,
        sitePrimPath: String?,
        layer: USDZResolvedLayer
    ) -> String? {
        if let targetPrimPath {
            return targetPrimPath
        }
        guard sitePrimPath != nil,
              let defaultPrim = layer.defaultPrim ?? layer.scene?.defaultPrim else {
            return nil
        }
        return absolutePrimPath(defaultPrim)
    }

    private func rewrittenPrimPath(
        _ primPath: String,
        replacing sourcePrimPath: String,
        with destinationPrimPath: String
    ) -> String? {
        if primPath == sourcePrimPath {
            return destinationPrimPath
        }
        if sourcePrimPath == "/" {
            return "\(destinationPrimPath)\(primPath)"
        }
        let descendantPrefix = "\(sourcePrimPath)/"
        guard primPath.hasPrefix(descendantPrefix) else {
            return nil
        }
        let suffixStart = primPath.index(primPath.startIndex, offsetBy: sourcePrimPath.count)
        return "\(destinationPrimPath)\(primPath[suffixStart...])"
    }

    private func absolutePrimPath(_ primName: String) -> String {
        primName.hasPrefix("/") ? primName : "/\(primName)"
    }

    private func lastPrimName(in primPath: String) -> String? {
        primPath.split(separator: "/").last.map(String.init)
    }

    private func parentPrimPath(from path: String) -> String? {
        guard path != "/" else {
            return nil
        }
        guard let slash = path.lastIndex(of: "/") else {
            return nil
        }
        if slash == path.startIndex {
            return "/"
        }
        return String(path[..<slash])
    }

    private func readResolvedLayers(defaultLayerPath: String, in archive: USDZArchive) throws -> [USDZResolvedLayer] {
        var visitedLayerPaths: Set<String> = []
        var pendingLayerPaths = [defaultLayerPath]
        var resolvedLayers: [USDZResolvedLayer] = []

        while let layerPath = pendingLayerPaths.first {
            pendingLayerPaths.removeFirst()
            guard visitedLayerPaths.insert(layerPath).inserted else {
                continue
            }

            let layer = try readLayer(at: layerPath, in: archive)
            resolvedLayers.append(layer)
            for assetPath in layer.composition.assetPaths {
                guard let resolvedLayerPath = try resolvedLayerPath(
                    forArcAssetPath: assetPath,
                    referencedFrom: layerPath,
                    in: archive
                ) else {
                    throw USDError.invalidData(
                        "USDZ package could not resolve asset \(assetPath) from \(layerPath)."
                    )
                }
                pendingLayerPaths.append(resolvedLayerPath)
            }
        }
        return resolvedLayers
    }

    private func resolvedLayerPath(
        forArcAssetPath assetPath: String,
        referencedFrom sourceLayerPath: String,
        in archive: USDZArchive
    ) throws -> String? {
        guard !assetPath.isEmpty else {
            return sourceLayerPath
        }
        return try archive.resolveLayerPath(for: assetPath, referencedFrom: sourceLayerPath)
    }

    private func readLayer(
        at layerPath: String,
        in archive: USDZArchive,
        options: USDReadingOptions = .default
    ) throws -> USDZResolvedLayer {
        let entryPath = try resolvedEntryPath(for: layerPath)
        let data = try archive.layerData(at: layerPath)
        switch fileExtension(for: entryPath) {
        case "usda":
            return try readUSDA(data, layerPath: layerPath, options: options)
        case "usd":
            if data.starts(with: USDCReaderSignature.bytes) {
                return try readUSDC(data, layerPath: layerPath, options: options)
            }
            return try readUSDA(data, layerPath: layerPath, options: options)
        case "usdc":
            return try readUSDC(data, layerPath: layerPath, options: options)
        default:
            throw USDError.unsupportedFeature("USDZ layer \(layerPath) is not a USD layer.")
        }
    }

    private func readUSDA(_ data: Data, layerPath: String, options: USDReadingOptions) throws -> USDZResolvedLayer {
        let layer = try textReader.readLayer(from: data)
        let scene: USDScene?
        if layerContainsDefMesh(layer) {
            scene = try textReader.read(from: data, options: options)
        } else {
            scene = nil
        }
        return USDZResolvedLayer(
            path: layerPath,
            defaultPrim: layer.defaultPrim,
            metersPerUnit: layer.metersPerUnit,
            upAxis: layer.upAxis,
            composition: layer.composition,
            primTransforms: layer.primTransforms,
            resetXformStackPrimPaths: layer.resetXformStackPrimPaths,
            scene: scene
        )
    }

    private func readUSDC(_ data: Data, layerPath: String, options: USDReadingOptions) throws -> USDZResolvedLayer {
        let reader = USDCReader()
        let layer = try reader.readLayer(from: data)
        let scene = layerContainsDefMesh(layer)
            ? try reader.read(from: data, options: options)
            : nil
        return USDZResolvedLayer(
            path: layerPath,
            defaultPrim: layer.defaultPrim,
            metersPerUnit: layer.metersPerUnit,
            upAxis: layer.upAxis,
            composition: layer.composition,
            primTransforms: layer.primTransforms,
            resetXformStackPrimPaths: layer.resetXformStackPrimPaths,
            scene: scene
        )
    }

    private func layerContainsDefMesh(_ layer: USDALayer) -> Bool {
        layer.specs.contains { spec in
            spec.specType == .prim && spec.specifier == .def && spec.typeName == "Mesh"
        }
    }

    private func layerContainsDefMesh(_ layer: USDCLayer) -> Bool {
        layer.prims.contains { spec in
            spec.typeName == "Mesh" && (spec.specifier == nil || spec.specifier == .def)
        }
    }

    private func layerOptions(
        from options: USDReadingOptions,
        applying layerOffset: SdfLayerOffset
    ) throws -> USDReadingOptions {
        guard let timeCode = options.timeCode else {
            return options
        }
        return USDReadingOptions(
            timeCode: try layerOffset.layerTime(forStageTime: timeCode),
            timeSampleInterpolation: options.timeSampleInterpolation
        )
    }

    private func resolvedEntryPath(for layerPath: String) throws -> String {
        guard let entryPath = try USDZLayerPath.parse(layerPath).entryPaths.last else {
            throw USDError.invalidData("USDZ layer path is empty.")
        }
        return entryPath
    }

    private func fileExtension(for path: String) -> String {
        guard let lastComponent = path.split(separator: "/").last,
              let extensionStart = lastComponent.lastIndex(of: ".") else {
            return ""
        }
        return String(lastComponent[lastComponent.index(after: extensionStart)...]).lowercased()
    }
}

private struct USDZResolvedLayer: Sendable {
    var path: String
    var defaultPrim: String?
    var metersPerUnit: Double?
    var upAxis: USDUpAxis?
    var composition: USDLayerComposition
    var primTransforms: [String: USDTransformMatrix4x4]
    var resetXformStackPrimPaths: Set<String>
    var scene: USDScene?
}

private struct USDZResolvedLayerInstance: Sendable {
    var layer: USDZResolvedLayer
    var sitePrimPath: String?
    var siteTransform: USDTransformMatrix4x4
    var targetPrimPath: String?
    var layerOffset: SdfLayerOffset
}

private struct USDZPendingLayerInstance: Sendable {
    var layerPath: String
    var sitePrimPath: String?
    var siteTransform: USDTransformMatrix4x4
    var targetPrimPath: String?
    var layerOffset: SdfLayerOffset
    var ancestorKeys: Set<USDZLayerInstanceKey>
}

private struct USDZLayerInstanceKey: Sendable, Hashable {
    var layerPath: String
    var sitePrimPath: String?
    var targetPrimPath: String?
}

private struct USDZLayerParseKey: Sendable, Hashable {
    var layerPath: String
    var options: USDReadingOptions
}

private enum USDCReaderSignature {
    static let bytes = Data("PXR-USDC".utf8)
}
