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
        guard data.starts(with: Self.fileSignature) else {
            throw USDImportError.invalidData("USDZ data is missing the ZIP signature.")
        }

        let archive = try USDZArchive(data: data)
        guard let defaultLayer = archive.defaultLayer else {
            throw USDImportError.invalidData("USDZ package contains no entries.")
        }
        guard defaultLayer.isUSDLayer else {
            throw USDImportError.unsupportedFeature("USDZ default layer must be the first file and use a USD extension.")
        }
        return try readResolvedScene(defaultLayerPath: defaultLayer.path, in: archive)
    }

    private func readResolvedScene(defaultLayerPath: String, in archive: USDZArchive) throws -> USDScene {
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

        let meshes = resolvedLayers.flatMap { $0.scene?.meshes ?? [] }
        guard !meshes.isEmpty else {
            throw USDImportError.invalidData("USDZ scene contains no Mesh prims.")
        }
        let rootLayer = resolvedLayers.first
        let firstScene = resolvedLayers.compactMap(\.scene).first
        return USDScene(
            defaultPrim: rootLayer?.defaultPrim ?? rootLayer?.scene?.defaultPrim ?? firstScene?.defaultPrim,
            metersPerUnit: rootLayer?.metersPerUnit ?? rootLayer?.scene?.metersPerUnit ?? firstScene?.metersPerUnit ?? 1,
            upAxis: rootLayer?.upAxis ?? rootLayer?.scene?.upAxis ?? firstScene?.upAxis ?? .y,
            meshes: meshes
        )
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
    var defaultPrim: String?
    var metersPerUnit: Double?
    var upAxis: USDUpAxis?
    var composition: USDLayerComposition
    var scene: USDScene?
}

private enum USDCReaderSignature {
    static let bytes = Data("PXR-USDC".utf8)
}
