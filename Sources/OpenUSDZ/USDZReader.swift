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
                    hasScene: layer.hasScene
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

    fileprivate func resolveRootLayerPath(_ rootLayerPath: String, in archive: USDZArchive) throws -> String {
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
        let provider = USDZLayerProvider(archive: archive, reader: self)
        guard let rootLayer = try provider.layer(forResolvedIdentifier: defaultLayerPath) else {
            throw USDError.invalidData("USDZ package could not load root layer \(defaultLayerPath).")
        }
        let flattenedLayer: USDALayer
        do {
            flattenedLayer = try USDStage(rootLayer: rootLayer).flattenedLayer(
                resolvingWith: provider,
                rootIdentifier: defaultLayerPath
            )
        } catch USDError.invalidData(let message) where message.contains(
            "has no defaultPrim for an unqualified reference"
        ) {
            flattenedLayer = rootLayer.toUSDALayer()
        }
        let metadataFallback = try sceneMetadataFallback(defaultLayerPath: defaultLayerPath, in: archive)
        return try USDZLayerSceneMaterializer(textReader: textReader).scene(
            from: flattenedLayer,
            options: options,
            metadataFallback: metadataFallback
        )
    }

    private func sceneMetadataFallback(
        defaultLayerPath: String,
        in archive: USDZArchive
    ) throws -> USDZSceneMetadataFallback {
        let layers = try readResolvedLayers(defaultLayerPath: defaultLayerPath, in: archive)
        return USDZSceneMetadataFallback(
            metersPerUnit: layers.compactMap(\.metersPerUnit).first,
            upAxis: layers.compactMap(\.upAxis).first
        )
    }

    private func readResolvedLayers(defaultLayerPath: String, in archive: USDZArchive) throws -> [USDZResolvedLayer] {
        var visitedLayerPaths: Set<String> = []
        var pendingLayerPaths = [defaultLayerPath]
        var resolvedLayers: [USDZResolvedLayer] = []

        var cursor = 0
        while cursor < pendingLayerPaths.count {
            let layerPath = pendingLayerPaths[cursor]
            cursor += 1
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
        in archive: USDZArchive
    ) throws -> USDZResolvedLayer {
        let sdfLayer = try readSdfLayer(at: layerPath, in: archive)
        return USDZResolvedLayer(
            path: layerPath,
            defaultPrim: sdfLayer.defaultPrim,
            metersPerUnit: sdfLayer.metersPerUnit,
            upAxis: sdfLayer.upAxis,
            composition: sdfLayer.composition,
            primTransforms: sdfLayer.primTransforms,
            resetXformStackPrimPaths: sdfLayer.resetXformStackPrimPaths,
            hasScene: layerContainsMaterializedMesh(sdfLayer)
        )
    }

    fileprivate func readSdfLayer(at layerPath: String, in archive: USDZArchive) throws -> SdfLayer {
        let entryPath = try resolvedEntryPath(for: layerPath)
        let data = try archive.layerData(at: layerPath)
        switch fileExtension(for: entryPath) {
        case "usda":
            return try SdfLayer(usdLayer: textReader.readLayer(from: data), identifier: layerPath)
        case "usd":
            if data.starts(with: USDCReaderSignature.bytes) {
                return try SdfLayer(usdcLayer: USDCReader().readLayer(from: data), identifier: layerPath)
            }
            return try SdfLayer(usdLayer: textReader.readLayer(from: data), identifier: layerPath)
        case "usdc":
            return try SdfLayer(usdcLayer: USDCReader().readLayer(from: data), identifier: layerPath)
        default:
            throw USDError.unsupportedFeature("USDZ layer \(layerPath) is not a USD layer.")
        }
    }

    private func layerContainsMaterializedMesh(_ layer: SdfLayer) -> Bool {
        layer.specs.contains { spec in
            guard spec.specType == .prim, spec.specifier == .def else {
                return false
            }
            if spec.typeName == "Mesh" {
                return true
            }
            let attributeNames = Set(directAttributeSpecs(for: spec.path, in: layer).map {
                propertyName(for: $0.path, parentPath: spec.path)
            })
            return attributeNames.contains("points")
                && attributeNames.contains("faceVertexCounts")
                && attributeNames.contains("faceVertexIndices")
        }
    }

    private func directAttributeSpecs(for primPath: SdfPath, in layer: SdfLayer) -> [SdfSpec] {
        let prefix = primPath.rawValue + "."
        return layer.specs.filter { spec in
            guard spec.specType == .attribute, spec.path.rawValue.hasPrefix(prefix) else {
                return false
            }
            let propertyName = propertyName(for: spec.path, parentPath: primPath)
            return !propertyName.contains("/") && !propertyName.contains("[")
        }
    }

    private func propertyName(for propertyPath: SdfPath, parentPath: SdfPath) -> String {
        String(propertyPath.rawValue.dropFirst(parentPath.rawValue.count + 1))
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
    var hasScene: Bool
}

private struct USDZLayerProvider: USDLayerProvider {
    var archive: USDZArchive
    var reader: USDZReader

    func resolveIdentifier(_ identifier: String, referencedFrom sourceIdentifier: String?) throws -> String? {
        guard !identifier.isEmpty else {
            return sourceIdentifier
        }
        if let sourceIdentifier {
            return try archive.resolveLayerPath(for: identifier, referencedFrom: sourceIdentifier)
        }
        return try reader.resolveRootLayerPath(identifier, in: archive)
    }

    func layer(forResolvedIdentifier identifier: String) throws -> SdfLayer? {
        try reader.readSdfLayer(at: identifier, in: archive)
    }
}

private struct USDZSceneMetadataFallback {
    var metersPerUnit: Double?
    var upAxis: USDUpAxis?
}

private struct USDZLayerSceneMaterializer {
    var textReader: USDAReader

    func scene(
        from layer: USDALayer,
        options: USDReadingOptions,
        metadataFallback: USDZSceneMetadataFallback
    ) throws -> USDScene {
        let meshes = try layer.specs
            .filter { isMaterializedMeshSpec($0, in: layer) }
            .map { try materializeMesh($0, in: layer, options: options) }
        guard !meshes.isEmpty else {
            throw USDError.invalidData("USDA scene contains no Mesh prims.")
        }
        return USDScene(
            defaultPrim: layer.defaultPrim,
            metersPerUnit: layer.metersPerUnit ?? metadataFallback.metersPerUnit ?? 0.01,
            upAxis: layer.upAxis ?? metadataFallback.upAxis ?? .y,
            meshes: meshes
        )
    }

    private func isMaterializedMeshSpec(_ spec: USDLayerSpec, in layer: USDALayer) -> Bool {
        guard spec.specType == .prim, spec.specifier == .def else {
            return false
        }
        if spec.typeName == "Mesh" {
            return true
        }
        let attributeNames = Set(directAttributeSpecs(for: spec.path, in: layer).map {
            propertyName(for: $0.path, parentPath: spec.path)
        })
        return attributeNames.contains("points")
            && attributeNames.contains("faceVertexCounts")
            && attributeNames.contains("faceVertexIndices")
    }

    private func materializeMesh(
        _ meshSpec: USDLayerSpec,
        in layer: USDALayer,
        options: USDReadingOptions
    ) throws -> USDMesh {
        let untransformedMesh = try parseUntransformedMesh(meshSpec, in: layer, options: options)
        let transform = layer.primTransforms[meshSpec.path] ?? .identity
        return try applying(transform, to: untransformedMesh, originalSpec: meshSpec)
    }

    private func parseUntransformedMesh(
        _ meshSpec: USDLayerSpec,
        in layer: USDALayer,
        options: USDReadingOptions
    ) throws -> USDMesh {
        let meshPath = "/Mesh"
        var propertySpecs: [USDLayerSpec] = []
        for spec in directAttributeSpecs(for: meshSpec.path, in: layer) {
            let propertyName = propertyName(for: spec.path, parentPath: meshSpec.path)
            guard propertyName != "xformOpOrder", !propertyName.hasPrefix("xformOp:") else {
                continue
            }
            var rewrittenSpec = spec
            rewrittenSpec.path = "\(meshPath).\(propertyName)"
            propertySpecs.append(rewrittenSpec)
        }
        let layer = USDALayer(defaultPrim: "Mesh", specs: [
            USDLayerSpec(path: "/", specType: .pseudoRoot),
            USDLayerSpec(path: meshPath, specType: .prim, specifier: .def, typeName: "Mesh"),
        ] + propertySpecs)
        let data = try USDAWriter().data(for: layer)
        let scene = try textReader.read(from: data, options: options)
        guard let mesh = scene.meshes.first else {
            throw USDError.invalidData("USDA scene contains no Mesh prims.")
        }
        return mesh
    }

    private func directAttributeSpecs(for primPath: String, in layer: USDALayer) -> [USDLayerSpec] {
        let prefix = primPath + "."
        return layer.specs.filter { spec in
            guard spec.specType == .attribute, spec.path.hasPrefix(prefix) else {
                return false
            }
            let propertyName = propertyName(for: spec.path, parentPath: primPath)
            return !propertyName.contains("/") && !propertyName.contains("[")
        }
    }

    private func propertyName(for propertyPath: String, parentPath: String) -> String {
        String(propertyPath.dropFirst(parentPath.count + 1))
    }

    private func applying(
        _ transform: USDTransformMatrix4x4,
        to mesh: USDMesh,
        originalSpec: USDLayerSpec
    ) throws -> USDMesh {
        var transformedMesh = mesh
        transformedMesh.name = primName(for: originalSpec.path)
        transformedMesh.primPath = originalSpec.path
        transformedMesh.points = try mesh.points.map { try transform.transform($0) }
        transformedMesh.normals = try mesh.normals.map { try transform.transform(normal: $0) }
        transformedMesh.extent = try transformedExtent(mesh.extent, applying: transform)
        return transformedMesh
    }

    private func transformedExtent(
        _ extent: [USDPoint3D]?,
        applying transform: USDTransformMatrix4x4
    ) throws -> [USDPoint3D]? {
        guard let extent else {
            return nil
        }
        guard extent.count == 2 else {
            throw USDError.invalidData("USDA extent must contain exactly two points.")
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

    private func primName(for path: String) -> String? {
        guard path != "/", let slashIndex = path.lastIndex(of: "/") else {
            return nil
        }
        return String(path[path.index(after: slashIndex)...])
    }
}

private enum USDCReaderSignature {
    static let bytes = Data("PXR-USDC".utf8)
}
