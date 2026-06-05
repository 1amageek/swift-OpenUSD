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
        let archive = try readArchive(from: data)
        let defaultLayerPath = try defaultLayerPath(in: archive)
        return try readResolvedScene(defaultLayerPath: defaultLayerPath, in: archive)
    }

    public func read(from data: Data, rootLayerPath: String) throws -> USDScene {
        let archive = try readArchive(from: data)
        let resolvedRootLayerPath = try resolveRootLayerPath(rootLayerPath, in: archive)
        return try readResolvedScene(defaultLayerPath: resolvedRootLayerPath, in: archive)
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

    @available(*, deprecated, message: "Use read(from:rootLayerPath:) instead.")
    public func read(from data: Data, at rootPath: String) throws -> USDScene {
        try read(from: data, rootLayerPath: rootPath)
    }

    @available(*, deprecated, message: "Use readLayerGraph(from:rootLayerPath:) instead.")
    public func readLayerGraph(from data: Data, at rootPath: String) throws -> USDZLayerGraph {
        try readLayerGraph(from: data, rootLayerPath: rootPath)
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
            throw USDImportError.invalidData("USDZ data is missing the ZIP signature.")
        }
        return try USDZArchive(data: data)
    }

    private func defaultLayerPath(in archive: USDZArchive) throws -> String {
        guard let defaultLayer = archive.defaultLayer else {
            throw USDImportError.invalidData("USDZ package contains no entries.")
        }
        if defaultLayer.isUSDLayer {
            return defaultLayer.path
        }
        if defaultLayer.fileExtension == "usdz" {
            let nestedArchive = try USDZArchive(data: defaultLayer.data)
            guard let nestedDefaultLayer = nestedArchive.defaultLayer,
                  nestedDefaultLayer.isUSDLayer else {
                throw USDImportError.unsupportedFeature(
                    "USDZ nested default package \(defaultLayer.path) must contain a USD default layer."
                )
            }
            return "\(defaultLayer.path)[\(nestedDefaultLayer.path)]"
        }
        throw USDImportError.unsupportedFeature("USDZ default layer must be the first file and use a USD extension.")
    }

    private func resolveRootLayerPath(_ rootLayerPath: String, in archive: USDZArchive) throws -> String {
        let layerPath = try USDZLayerPath.parse(rootLayerPath)
        guard !layerPath.entryPaths.isEmpty else {
            throw USDImportError.invalidData("USDZ layer path is empty.")
        }
        return try resolveRootLayerPath(entryPaths: layerPath.entryPaths, in: archive).stringValue
    }

    private func resolveRootLayerPath(entryPaths: [String], in archive: USDZArchive) throws -> USDZLayerPath {
        var currentArchive = archive
        var resolvedEntryPaths: [String] = []
        for (index, entryPath) in entryPaths.enumerated() {
            guard let entry = currentArchive.entry(at: entryPath) else {
                throw USDImportError.invalidData("USDZ package is missing entry \(entryPath).")
            }

            resolvedEntryPaths.append(entry.path)
            let isLastEntry = index == entryPaths.count - 1
            if isLastEntry {
                if entry.isUSDLayer {
                    return USDZLayerPath(entryPaths: resolvedEntryPaths)
                }
                guard entry.fileExtension == "usdz" else {
                    throw USDImportError.unsupportedFeature("USDZ entry \(entry.path) is not a USD layer.")
                }
                let nestedArchive = try USDZArchive(data: entry.data)
                let nestedDefaultLayerPath = try defaultLayerPath(in: nestedArchive)
                let nestedDefaultEntryPaths = try USDZLayerPath.parse(nestedDefaultLayerPath).entryPaths
                return USDZLayerPath(
                    entryPaths: resolvedEntryPaths + nestedDefaultEntryPaths
                )
            }

            guard entry.fileExtension == "usdz" else {
                throw USDImportError.unsupportedFeature("USDZ entry \(entry.path) is not a nested USDZ package.")
            }
            currentArchive = try USDZArchive(data: entry.data)
        }

        throw USDImportError.invalidData("USDZ layer path is empty.")
    }

    private func readResolvedScene(defaultLayerPath: String, in archive: USDZArchive) throws -> USDScene {
        let resolvedLayerInstances = try readResolvedLayerInstances(defaultLayerPath: defaultLayerPath, in: archive)
        let meshes = resolvedLayerInstances.flatMap { layerInstance in
            materializedMeshes(in: layerInstance)
        }
        guard !meshes.isEmpty else {
            throw USDImportError.invalidData("USDZ scene contains no Mesh prims.")
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
        in archive: USDZArchive
    ) throws -> [USDZResolvedLayerInstance] {
        var visitedLayerInstances: Set<USDZLayerInstanceKey> = []
        var pendingLayerInstances = [
            USDZPendingLayerInstance(
                layerPath: defaultLayerPath,
                sitePrimPath: nil as String?,
                targetPrimPath: nil as String?
            )
        ]
        var resolvedLayerInstances: [USDZResolvedLayerInstance] = []

        while let pendingLayerInstance = pendingLayerInstances.first {
            pendingLayerInstances.removeFirst()
            let instanceKey = USDZLayerInstanceKey(
                layerPath: pendingLayerInstance.layerPath,
                sitePrimPath: pendingLayerInstance.sitePrimPath,
                targetPrimPath: pendingLayerInstance.targetPrimPath
            )
            guard visitedLayerInstances.insert(instanceKey).inserted else {
                continue
            }

            let layer = try readLayer(at: pendingLayerInstance.layerPath, in: archive)
            let effectiveTargetPrimPath = effectiveTargetPrimPath(
                targetPrimPath: pendingLayerInstance.targetPrimPath,
                sitePrimPath: pendingLayerInstance.sitePrimPath,
                layer: layer
            )
            resolvedLayerInstances.append(USDZResolvedLayerInstance(
                layer: layer,
                sitePrimPath: pendingLayerInstance.sitePrimPath,
                targetPrimPath: effectiveTargetPrimPath
            ))
            for assetPath in layer.composition.subLayerAssetPaths {
                guard let resolvedLayerPath = try archive.resolveLayerPath(
                    for: assetPath,
                    referencedFrom: pendingLayerInstance.layerPath
                ) else {
                    throw USDImportError.invalidData(
                        "USDZ package could not resolve asset \(assetPath) from \(pendingLayerInstance.layerPath)."
                    )
                }
                pendingLayerInstances.append(USDZPendingLayerInstance(
                    layerPath: resolvedLayerPath,
                    sitePrimPath: pendingLayerInstance.sitePrimPath,
                    targetPrimPath: effectiveTargetPrimPath
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
                guard let resolvedLayerPath = try archive.resolveLayerPath(
                    for: arc.assetPath,
                    referencedFrom: pendingLayerInstance.layerPath
                ) else {
                    throw USDImportError.invalidData(
                        "USDZ package could not resolve asset \(arc.assetPath) from \(pendingLayerInstance.layerPath)."
                    )
                }
                pendingLayerInstances.append(USDZPendingLayerInstance(
                    layerPath: resolvedLayerPath,
                    sitePrimPath: composedSitePrimPath,
                    targetPrimPath: arc.targetPrimPath
                ))
            }
        }
        return resolvedLayerInstances
    }

    private func materializedMeshes(in layerInstance: USDZResolvedLayerInstance) -> [USDMesh] {
        let targetPrimPath = effectiveTargetPrimPath(
            targetPrimPath: layerInstance.targetPrimPath,
            sitePrimPath: layerInstance.sitePrimPath,
            layer: layerInstance.layer
        )
        let meshes = filteredMeshes(in: layerInstance.layer.scene, matching: targetPrimPath)
        guard let sitePrimPath = layerInstance.sitePrimPath,
              let targetPrimPath else {
            return meshes
        }
        return meshes.map { mesh in
            rewriting(mesh, sourceTargetPrimPath: targetPrimPath, sitePrimPath: sitePrimPath)
        }
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
        sitePrimPath: String
    ) -> USDMesh {
        guard let primPath = mesh.primPath,
              let rewrittenPrimPath = rewrittenPrimPath(
                  primPath,
                  replacing: sourceTargetPrimPath,
                  with: sitePrimPath
              ) else {
            return mesh
        }
        var rewrittenMesh = mesh
        rewrittenMesh.primPath = rewrittenPrimPath
        rewrittenMesh.name = lastPrimName(in: rewrittenPrimPath) ?? rewrittenMesh.name
        return rewrittenMesh
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
                guard let resolvedLayerPath = try archive.resolveLayerPath(for: assetPath, referencedFrom: layerPath) else {
                    throw USDImportError.invalidData(
                        "USDZ package could not resolve asset \(assetPath) from \(layerPath)."
                    )
                }
                pendingLayerPaths.append(resolvedLayerPath)
            }
        }
        return resolvedLayers
    }

    private func readLayer(at layerPath: String, in archive: USDZArchive) throws -> USDZResolvedLayer {
        let entryPath = try resolvedEntryPath(for: layerPath)
        let data = try archive.data(for: layerPath)
        switch fileExtension(for: entryPath) {
        case "usda":
            return try readUSDA(data, layerPath: layerPath)
        case "usd":
            if data.starts(with: USDCReaderSignature.bytes) {
                return try readUSDC(data, layerPath: layerPath)
            }
            return try readUSDA(data, layerPath: layerPath)
        case "usdc":
            return try readUSDC(data, layerPath: layerPath)
        default:
            throw USDImportError.unsupportedFeature("USDZ layer \(layerPath) is not a USD layer.")
        }
    }

    private func readUSDA(_ data: Data, layerPath: String) throws -> USDZResolvedLayer {
        let layer = try textReader.readLayer(from: data)
        let scene: USDScene?
        if dataContainsMeshDefinition(data) {
            scene = try textReader.read(from: data)
        } else {
            scene = nil
        }
        return USDZResolvedLayer(
            path: layerPath,
            defaultPrim: layer.defaultPrim,
            metersPerUnit: layer.metersPerUnit,
            upAxis: layer.upAxis,
            composition: layer.composition,
            scene: scene
        )
    }

    private func readUSDC(_ data: Data, layerPath: String) throws -> USDZResolvedLayer {
        let reader = USDCReader()
        let layer = try reader.readLayer(from: data)
        let scene = layer.prims.contains { $0.typeName == "Mesh" }
            ? try reader.read(from: data)
            : nil
        return USDZResolvedLayer(
            path: layerPath,
            defaultPrim: layer.defaultPrim,
            metersPerUnit: layer.metersPerUnit,
            upAxis: layer.upAxis,
            composition: layer.composition,
            scene: scene
        )
    }

    private func dataContainsMeshDefinition(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("def Mesh")
    }

    private func resolvedEntryPath(for layerPath: String) throws -> String {
        guard let entryPath = try USDZLayerPath.parse(layerPath).entryPaths.last else {
            throw USDImportError.invalidData("USDZ layer path is empty.")
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
    var scene: USDScene?
}

private struct USDZResolvedLayerInstance: Sendable {
    var layer: USDZResolvedLayer
    var sitePrimPath: String?
    var targetPrimPath: String?
}

private struct USDZPendingLayerInstance: Sendable {
    var layerPath: String
    var sitePrimPath: String?
    var targetPrimPath: String?
}

private struct USDZLayerInstanceKey: Sendable, Hashable {
    var layerPath: String
    var sitePrimPath: String?
    var targetPrimPath: String?
}

private enum USDCReaderSignature {
    static let bytes = Data("PXR-USDC".utf8)
}
