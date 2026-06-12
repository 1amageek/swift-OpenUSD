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
        let flattenedLayer = try USDStage(rootLayer: rootLayer).flattenedLayer(
            resolvingWith: provider,
            rootIdentifier: defaultLayerPath,
            missingDefaultPrimPolicy: .skipArc
        )
        let metadataFallback = try sceneMetadataFallback(defaultLayerPath: defaultLayerPath, in: archive)
        return try USDZLayerSceneMaterializer().scene(
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
        let untransformedMesh = try untransformedMesh(meshSpec, in: layer, options: options)
        let transform = layer.primTransforms[meshSpec.path] ?? .identity
        return try applying(transform, to: untransformedMesh, originalSpec: meshSpec)
    }

    private func untransformedMesh(
        _ meshSpec: USDLayerSpec,
        in layer: USDALayer,
        options: USDReadingOptions
    ) throws -> USDMesh {
        var attributes: [String: USDLayerSpec] = [:]
        for spec in directAttributeSpecs(for: meshSpec.path, in: layer) {
            let propertyName = propertyName(for: spec.path, parentPath: meshSpec.path)
            guard propertyName != "xformOpOrder", !propertyName.hasPrefix("xformOp:") else {
                continue
            }
            attributes[propertyName] = spec
        }
        let reader = USDZMeshAttributeReader(attributes: attributes)
        let points = try reader.requiredPoint3Array(named: "points", options: options)
        let faceVertexCounts = try reader.requiredIntArray(named: "faceVertexCounts", options: options)
        let faceVertexIndices = try reader.requiredIntArray(named: "faceVertexIndices", options: options)
        try USDMesh.validateTopology(
            pointCount: points.count,
            faceVertexCounts: faceVertexCounts,
            faceVertexIndices: faceVertexIndices
        )
        let textureCoordinates = try reader.optionalTextureCoordinates(options: options)
        let displayColor = try reader.optionalDisplayColor(options: options)
        let displayOpacity = try reader.optionalDisplayOpacity(options: options)
        if let textureCoordinates {
            try textureCoordinates.validate(pointCount: points.count, faceVertexCounts: faceVertexCounts)
        }
        if let displayColor {
            try displayColor.validate(pointCount: points.count, faceVertexCounts: faceVertexCounts)
        }
        if let displayOpacity {
            try displayOpacity.validate(pointCount: points.count, faceVertexCounts: faceVertexCounts)
        }
        return USDMesh(
            name: primName(for: meshSpec.path),
            primPath: meshSpec.path,
            points: points,
            faceVertexCounts: faceVertexCounts,
            faceVertexIndices: faceVertexIndices,
            normals: try reader.optionalPoint3Array(named: "normals", options: options) ?? [],
            normalsInterpolation: try reader.optionalMetadataString(named: "interpolation", for: "normals"),
            orientation: try reader.optionalOrientation(),
            subdivisionScheme: try reader.optionalString(named: "subdivisionScheme"),
            textureCoordinates: textureCoordinates,
            displayColor: displayColor,
            displayOpacity: displayOpacity,
            extent: try reader.optionalPoint3Array(named: "extent", options: options)
        )
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

private struct USDZMeshAttributeReader {
    var attributes: [String: USDLayerSpec]

    func requiredPoint3Array(named name: String, options: USDReadingOptions) throws -> [USDPoint3D] {
        guard let values = try optionalPoint3Array(named: name, options: options) else {
            throw USDError.missingRequiredField(name)
        }
        return values
    }

    func optionalPoint3Array(named name: String, options: USDReadingOptions) throws -> [USDPoint3D]? {
        guard let spec = attributes[name] else {
            return nil
        }
        if let sampled = try sampledPoint3Array(named: name, spec: spec, options: options) {
            switch sampled {
            case .value(let values):
                return values
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let field = spec.fields["default"] else {
            return nil
        }
        if isNoneField(field) {
            return nil
        }
        return try point3Array(from: field, name: name)
    }

    func requiredIntArray(named name: String, options: USDReadingOptions) throws -> [Int] {
        guard let values = try optionalIntArray(named: name, options: options) else {
            throw USDError.missingRequiredField(name)
        }
        guard !values.isEmpty else {
            throw USDError.invalidData("USDZ Mesh \(name) is empty.")
        }
        return values
    }

    func optionalString(named name: String) throws -> String? {
        guard let field = attributes[name]?.fields["default"] else {
            return nil
        }
        if isNoneField(field) {
            return nil
        }
        return try string(from: field, name: name)
    }

    func optionalOrientation() throws -> USDOrientation? {
        guard let value = try optionalString(named: "orientation") else {
            return nil
        }
        guard let orientation = USDOrientation(rawValue: value) else {
            throw USDError.invalidData("Unsupported USDZ orientation \(value).")
        }
        return orientation
    }

    func optionalTextureCoordinates(options: USDReadingOptions) throws -> USDTextureCoordinatePrimvar? {
        guard let values = try optionalPoint2Array(named: "primvars:st", options: options) else {
            return nil
        }
        return USDTextureCoordinatePrimvar(
            values: values,
            indices: try optionalIntArray(named: "primvars:st:indices", options: options),
            interpolation: try optionalMetadataString(named: "interpolation", for: "primvars:st")
        )
    }

    func optionalDisplayColor(options: USDReadingOptions) throws -> USDDisplayColorPrimvar? {
        guard let values = try optionalPoint3Array(named: "primvars:displayColor", options: options) else {
            return nil
        }
        return USDDisplayColorPrimvar(
            values: values.map { USDColorRGB(r: $0.x, g: $0.y, b: $0.z) },
            indices: try optionalIntArray(named: "primvars:displayColor:indices", options: options),
            interpolation: try optionalMetadataString(named: "interpolation", for: "primvars:displayColor")
        )
    }

    func optionalDisplayOpacity(options: USDReadingOptions) throws -> USDDisplayOpacityPrimvar? {
        guard let values = try optionalDoubleArray(named: "primvars:displayOpacity", options: options) else {
            return nil
        }
        return USDDisplayOpacityPrimvar(
            values: values,
            indices: try optionalIntArray(named: "primvars:displayOpacity:indices", options: options),
            interpolation: try optionalMetadataString(named: "interpolation", for: "primvars:displayOpacity")
        )
    }

    func optionalMetadataString(named metadataName: String, for attributeName: String) throws -> String? {
        guard let field = attributes[attributeName]?.fields[metadataName] else {
            return nil
        }
        if isNoneField(field) {
            return nil
        }
        return try string(from: field, name: "\(attributeName).\(metadataName)")
    }

    private func optionalPoint2Array(named name: String, options: USDReadingOptions) throws -> [USDPoint2D]? {
        guard let spec = attributes[name] else {
            return nil
        }
        if let sampled = try sampledPoint2Array(named: name, spec: spec, options: options) {
            switch sampled {
            case .value(let values):
                return values
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let field = spec.fields["default"] else {
            return nil
        }
        if isNoneField(field) {
            return nil
        }
        return try point2Array(from: field, name: name)
    }

    private func optionalIntArray(named name: String, options: USDReadingOptions) throws -> [Int]? {
        guard let spec = attributes[name] else {
            return nil
        }
        if let sampled = try sampledIntArray(named: name, spec: spec, options: options) {
            switch sampled {
            case .value(let values):
                return values
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let field = spec.fields["default"] else {
            return nil
        }
        if isNoneField(field) {
            return nil
        }
        return try intArray(from: field, name: name)
    }

    private func optionalDoubleArray(named name: String, options: USDReadingOptions) throws -> [Double]? {
        guard let spec = attributes[name] else {
            return nil
        }
        if let sampled = try sampledDoubleArray(named: name, spec: spec, options: options) {
            switch sampled {
            case .value(let values):
                return values
            case .blocked:
                return nil
            case .unresolved:
                break
            }
        }
        guard let field = spec.fields["default"] else {
            return nil
        }
        if isNoneField(field) {
            return nil
        }
        return try doubleArray(from: field, name: name)
    }
}

private extension USDZMeshAttributeReader {
    func sampledPoint3Array(
        named name: String,
        spec: USDLayerSpec,
        options: USDReadingOptions
    ) throws -> USDZSampleResolution<[USDPoint3D]>? {
        guard let field = spec.fields["timeSamples"] else {
            return nil
        }
        let samples = try point3Samples(from: field, name: name)
        return resolvedArraySample(samples, options: options, interpolate: interpolatePoint3Arrays)
    }

    func sampledPoint2Array(
        named name: String,
        spec: USDLayerSpec,
        options: USDReadingOptions
    ) throws -> USDZSampleResolution<[USDPoint2D]>? {
        guard let field = spec.fields["timeSamples"] else {
            return nil
        }
        let samples = try point2Samples(from: field, name: name)
        return resolvedArraySample(samples, options: options, interpolate: interpolatePoint2Arrays)
    }

    func sampledDoubleArray(
        named name: String,
        spec: USDLayerSpec,
        options: USDReadingOptions
    ) throws -> USDZSampleResolution<[Double]>? {
        guard let field = spec.fields["timeSamples"] else {
            return nil
        }
        let samples = try doubleSamples(from: field, name: name)
        return resolvedArraySample(samples, options: options, interpolate: interpolateDoubleArrays)
    }

    func sampledIntArray(
        named name: String,
        spec: USDLayerSpec,
        options: USDReadingOptions
    ) throws -> USDZSampleResolution<[Int]>? {
        guard let field = spec.fields["timeSamples"] else {
            return nil
        }
        let samples = try intSamples(from: field, name: name)
        return resolvedArraySample(samples, options: options, interpolate: nil)
    }

    func point3Samples(from field: USDLayerFieldValue, name: String) throws -> [USDZTimeSample<[USDPoint3D]>] {
        try samples(from: field, name: name, typedValue: point3Array, authoredValue: parsePoint3Array)
    }

    func point2Samples(from field: USDLayerFieldValue, name: String) throws -> [USDZTimeSample<[USDPoint2D]>] {
        try samples(from: field, name: name, typedValue: point2Array, authoredValue: parsePoint2Array)
    }

    func doubleSamples(from field: USDLayerFieldValue, name: String) throws -> [USDZTimeSample<[Double]>] {
        try samples(from: field, name: name, typedValue: doubleArray, authoredValue: parseDoubleArray)
    }

    func intSamples(from field: USDLayerFieldValue, name: String) throws -> [USDZTimeSample<[Int]>] {
        try samples(from: field, name: name, typedValue: intArray, authoredValue: parseIntArray)
    }

    func samples<Value>(
        from field: USDLayerFieldValue,
        name: String,
        typedValue: (SdfFieldValue, String) throws -> Value,
        authoredValue: (String, String) throws -> Value
    ) throws -> [USDZTimeSample<Value>] {
        switch field {
        case .timeSamples(let samples):
            return try samples.map { sample in
                USDZTimeSample(
                    timeCode: sample.timeCode,
                    value: try sample.value.map { try typedValue($0, name) }
                )
            }
        case .authored(let text):
            return try authoredTimeSamples(text).map { sample in
                USDZTimeSample(
                    timeCode: sample.timeCode,
                    value: try sample.value.map { try authoredValue($0, name) }
                )
            }
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name).timeSamples uses an unsupported field value.")
        }
    }

    func resolvedArraySample<Value>(
        _ samples: [USDZTimeSample<[Value]>],
        options: USDReadingOptions,
        interpolate: (([Value], [Value], Double) -> [Value]?)?
    ) -> USDZSampleResolution<[Value]> {
        resolvedSample(samples, options: options, interpolate: interpolate)
    }

    func resolvedSample<Value>(
        _ samples: [USDZTimeSample<Value>],
        options: USDReadingOptions,
        interpolate: ((Value, Value, Double) -> Value?)?
    ) -> USDZSampleResolution<Value> {
        guard let timeCode = options.timeCode else {
            guard let value = samples.first(where: { $0.value != nil })?.value else {
                return .unresolved
            }
            return .value(value)
        }
        var lowerSample: USDZTimeSample<Value>?
        var upperSample: USDZTimeSample<Value>?
        for sample in samples.sorted(by: { $0.timeCode < $1.timeCode }) {
            if sample.timeCode == timeCode {
                guard let value = sample.value else {
                    return .blocked
                }
                return .value(value)
            }
            if sample.timeCode < timeCode {
                lowerSample = sample
            } else {
                upperSample = sample
                break
            }
        }
        switch options.timeSampleInterpolation {
        case .held:
            guard let sample = lowerSample ?? upperSample else {
                return .unresolved
            }
            guard let value = sample.value else {
                return .blocked
            }
            return .value(value)
        case .linear:
            guard let lowerSample else {
                guard let upperSample else {
                    return .unresolved
                }
                guard let value = upperSample.value else {
                    return .blocked
                }
                return .value(value)
            }
            guard let lowerValue = lowerSample.value else {
                return .blocked
            }
            guard let upperSample, let upperValue = upperSample.value else {
                return .value(lowerValue)
            }
            let fraction = (timeCode - lowerSample.timeCode) / (upperSample.timeCode - lowerSample.timeCode)
            guard fraction.isFinite, let interpolate else {
                return .value(lowerValue)
            }
            return .value(interpolate(lowerValue, upperValue, fraction) ?? lowerValue)
        }
    }

    func interpolatePoint3Arrays(
        lower: [USDPoint3D],
        upper: [USDPoint3D],
        fraction: Double
    ) -> [USDPoint3D]? {
        guard lower.count == upper.count else {
            return nil
        }
        return zip(lower, upper).map {
            USDPoint3D(
                x: $0.x + ($1.x - $0.x) * fraction,
                y: $0.y + ($1.y - $0.y) * fraction,
                z: $0.z + ($1.z - $0.z) * fraction
            )
        }
    }

    func interpolatePoint2Arrays(
        lower: [USDPoint2D],
        upper: [USDPoint2D],
        fraction: Double
    ) -> [USDPoint2D]? {
        guard lower.count == upper.count else {
            return nil
        }
        return zip(lower, upper).map {
            USDPoint2D(
                x: $0.x + ($1.x - $0.x) * fraction,
                y: $0.y + ($1.y - $0.y) * fraction
            )
        }
    }

    func interpolateDoubleArrays(lower: [Double], upper: [Double], fraction: Double) -> [Double]? {
        guard lower.count == upper.count else {
            return nil
        }
        return zip(lower, upper).map { $0 + ($1 - $0) * fraction }
    }
}

private extension USDZMeshAttributeReader {
    func point3Array(from field: USDLayerFieldValue, name: String) throws -> [USDPoint3D] {
        switch field {
        case .authored(let text):
            return try parsePoint3Array(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) uses an unsupported point3 array value.")
        }
    }

    func point3Array(from value: SdfFieldValue, name: String) throws -> [USDPoint3D] {
        switch value {
        case .point3Array(let values):
            return values
        case .authored(let text):
            return try parsePoint3Array(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) time sample is not a point3 array.")
        }
    }

    func point2Array(from field: USDLayerFieldValue, name: String) throws -> [USDPoint2D] {
        switch field {
        case .authored(let text):
            return try parsePoint2Array(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) uses an unsupported point2 array value.")
        }
    }

    func point2Array(from value: SdfFieldValue, name: String) throws -> [USDPoint2D] {
        switch value {
        case .point2Array(let values):
            return values
        case .authored(let text):
            return try parsePoint2Array(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) time sample is not a point2 array.")
        }
    }

    func intArray(from field: USDLayerFieldValue, name: String) throws -> [Int] {
        switch field {
        case .authored(let text):
            return try parseIntArray(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) uses an unsupported int array value.")
        }
    }

    func intArray(from value: SdfFieldValue, name: String) throws -> [Int] {
        switch value {
        case .intArray(let values):
            return values
        case .authored(let text):
            return try parseIntArray(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) time sample is not an int array.")
        }
    }

    func doubleArray(from field: USDLayerFieldValue, name: String) throws -> [Double] {
        switch field {
        case .authored(let text):
            return try parseDoubleArray(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) uses an unsupported double array value.")
        }
    }

    func doubleArray(from value: SdfFieldValue, name: String) throws -> [Double] {
        switch value {
        case .doubleArray(let values), .doubleVector(let values), .timeCodeArray(let values):
            return values
        case .authored(let text):
            return try parseDoubleArray(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) time sample is not a double array.")
        }
    }

    func string(from field: USDLayerFieldValue, name: String) throws -> String {
        switch field {
        case .authored(let text):
            return try parseString(text, name)
        default:
            throw USDError.unsupportedFeature("USDZ Mesh \(name) uses an unsupported string value.")
        }
    }
}

private struct USDZTimeSample<Value> {
    var timeCode: Double
    var value: Value?
}

private enum USDZSampleResolution<Value> {
    case value(Value)
    case blocked
    case unresolved
}

private extension USDZMeshAttributeReader {
    func parsePoint3Array(_ text: String, _ name: String) throws -> [USDPoint3D] {
        try parseTupleArray(text, expectedCount: 3, name: name).map {
            USDPoint3D(x: $0[0], y: $0[1], z: $0[2])
        }
    }

    func parsePoint2Array(_ text: String, _ name: String) throws -> [USDPoint2D] {
        try parseTupleArray(text, expectedCount: 2, name: name).map {
            USDPoint2D(x: $0[0], y: $0[1])
        }
    }

    func parseIntArray(_ text: String, _ name: String) throws -> [Int] {
        try arrayScalarTokens(text, name: name).map { token in
            guard let value = Int(token) else {
                throw USDError.invalidData("USDZ Mesh \(name) contains a non-integer value.")
            }
            return value
        }
    }

    func parseDoubleArray(_ text: String, _ name: String) throws -> [Double] {
        try arrayScalarTokens(text, name: name).map { token in
            guard let value = Double(token), value.isFinite else {
                throw USDError.invalidData("USDZ Mesh \(name) contains a non-finite value.")
            }
            return value
        }
    }

    func parseString(_ text: String, _ name: String) throws -> String {
        var cursor = text.startIndex
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex else {
            return ""
        }
        if text[cursor] == "\"" || text[cursor] == "'" {
            let value = try quotedString(in: text, index: &cursor)
            skipWhitespace(in: text, index: &cursor)
            guard cursor == text.endIndex else {
                throw USDError.invalidData("USDZ Mesh \(name) string contains trailing content.")
            }
            return value
        }
        return removingLineComments(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parseTupleArray(_ text: String, expectedCount: Int, name: String) throws -> [[Double]] {
        let body = try bracketBody(text, name: name)
        var cursor = body.startIndex
        var tuples: [[Double]] = []
        while true {
            skipSeparators(in: body, index: &cursor)
            guard cursor < body.endIndex else {
                break
            }
            guard body[cursor] == "(" else {
                throw USDError.invalidData("USDZ Mesh \(name) tuple array contains unexpected content.")
            }
            let close = try matchingDelimiter(in: body, from: cursor, open: "(", close: ")")
            let tupleBody = String(body[body.index(after: cursor)..<close])
            tuples.append(try parseNumericTupleBody(tupleBody, expectedCount: expectedCount, name: name))
            cursor = body.index(after: close)
        }
        guard !tuples.isEmpty else {
            throw USDError.invalidData("USDZ Mesh \(name) contains no tuples.")
        }
        return tuples
    }

    func parseNumericTupleBody(_ body: String, expectedCount: Int, name: String) throws -> [Double] {
        let tokens = removingLineComments(from: body).split { $0 == "," || $0.isWhitespace || $0.isNewline }
        guard tokens.count == expectedCount else {
            throw USDError.invalidData("USDZ Mesh \(name) tuple contains \(tokens.count) values.")
        }
        return try tokens.map { token in
            guard let value = Double(token), value.isFinite else {
                throw USDError.invalidData("USDZ Mesh \(name) tuple contains a non-finite number.")
            }
            return value
        }
    }

    func arrayScalarTokens(_ text: String, name: String) throws -> [Substring] {
        let body = try bracketBody(text, name: name)
        let tokens = removingLineComments(from: body).split { $0 == "," || $0.isWhitespace || $0.isNewline }
        guard !tokens.isEmpty else {
            throw USDError.invalidData("USDZ Mesh \(name) is empty.")
        }
        return tokens
    }

    func bracketBody(_ text: String, name: String) throws -> String {
        var cursor = text.startIndex
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "[" else {
            throw USDError.invalidData("USDZ Mesh \(name) is missing an opening bracket.")
        }
        let close = try matchingDelimiter(in: text, from: cursor, open: "[", close: "]")
        var trailing = text.index(after: close)
        skipWhitespace(in: text, index: &trailing)
        guard trailing == text.endIndex else {
            throw USDError.invalidData("USDZ Mesh \(name) contains trailing array content.")
        }
        return String(text[text.index(after: cursor)..<close])
    }

    func authoredTimeSamples(_ text: String) throws -> [USDZTimeSample<String>] {
        var cursor = text.startIndex
        skipWhitespace(in: text, index: &cursor)
        guard cursor < text.endIndex, text[cursor] == "{" else {
            throw USDError.invalidData("USDZ timeSamples is missing an opening brace.")
        }
        let closeBrace = try matchingDelimiter(in: text, from: cursor, open: "{", close: "}")
        let body = String(text[text.index(after: cursor)..<closeBrace])
        var bodyCursor = body.startIndex
        var samples: [USDZTimeSample<String>] = []
        var seenTimeCodes: Set<Double> = []
        while true {
            skipSeparators(in: body, index: &bodyCursor)
            guard bodyCursor < body.endIndex else {
                break
            }
            let timeStart = bodyCursor
            while bodyCursor < body.endIndex, isNumberLiteralCharacter(body[bodyCursor]) {
                bodyCursor = body.index(after: bodyCursor)
            }
            guard timeStart < bodyCursor,
                  let timeCode = Double(body[timeStart..<bodyCursor]),
                  timeCode.isFinite else {
                throw USDError.invalidData("USDZ timeSamples entry has an invalid timeCode.")
            }
            guard seenTimeCodes.insert(timeCode).inserted else {
                throw USDError.invalidData("USDZ timeSamples contains duplicate timeCode values.")
            }
            skipWhitespace(in: body, index: &bodyCursor)
            guard bodyCursor < body.endIndex, body[bodyCursor] == ":" else {
                throw USDError.invalidData("USDZ timeSamples entry is missing a colon.")
            }
            bodyCursor = body.index(after: bodyCursor)
            skipWhitespace(in: body, index: &bodyCursor)
            if isNone(at: bodyCursor, in: body) {
                samples.append(USDZTimeSample(timeCode: timeCode, value: nil))
                bodyCursor = body.index(bodyCursor, offsetBy: 4)
                continue
            }
            guard bodyCursor < body.endIndex, body[bodyCursor] == "[" else {
                throw USDError.invalidData("USDZ timeSamples entry is not an array value.")
            }
            let close = try matchingDelimiter(in: body, from: bodyCursor, open: "[", close: "]")
            samples.append(USDZTimeSample(timeCode: timeCode, value: String(body[bodyCursor...close])))
            bodyCursor = body.index(after: close)
        }
        guard !samples.isEmpty else {
            throw USDError.invalidData("USDZ timeSamples contains no samples.")
        }
        return samples.sorted { $0.timeCode < $1.timeCode }
    }

    func matchingDelimiter(
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
        throw USDError.invalidData("USDZ value delimiter is unterminated.")
    }

    func quotedString(in text: String, index: inout String.Index) throws -> String {
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
                    throw USDError.invalidData("USDZ string escape is unterminated.")
                }
            }
            value.append(text[index])
            index = text.index(after: index)
        }
        throw USDError.invalidData("USDZ string is unterminated.")
    }

    func skipWhitespace(in text: String, index: inout String.Index) {
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

    func skipSeparators(in text: String, index: inout String.Index) {
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

    func skipLineComment(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index] != "\n", text[index] != "\r" {
            index = text.index(after: index)
        }
    }

    func removingLineComments(from text: String) -> String {
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

    func isNumberLiteralCharacter(_ character: Character) -> Bool {
        character.isNumber || character == "." || character == "+" || character == "-" || character == "e" || character == "E"
    }

    func isNoneField(_ field: USDLayerFieldValue) -> Bool {
        guard case .authored(let text) = field else {
            return false
        }
        return isNoneValue(text)
    }

    func isNoneValue(_ text: String) -> Bool {
        removingLineComments(from: text).trimmingCharacters(in: .whitespacesAndNewlines) == "None"
    }

    func isNone(at index: String.Index, in text: String) -> Bool {
        guard let end = text.index(index, offsetBy: 4, limitedBy: text.endIndex) else {
            return false
        }
        guard text[index..<end] == "None" else {
            return false
        }
        if end < text.endIndex {
            let next = text[end]
            guard next.isWhitespace || next == "," || next == "}" else {
                return false
            }
        }
        return true
    }
}

private enum USDCReaderSignature {
    static let bytes = Data("PXR-USDC".utf8)
}
