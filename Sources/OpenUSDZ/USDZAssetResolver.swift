import OpenUSD

struct USDZAssetResolver: Sendable {
    let archive: USDZArchive

    func resolveLayerPath(for assetPath: String, referencedFrom sourceLayerPath: String) throws -> USDZLayerPath? {
        let sourceContext = try context(for: USDZLayerPath.parse(sourceLayerPath))
        let authoredLayerPath = try USDZLayerPath.parse(assetPath)
        guard let firstAuthoredEntryPath = authoredLayerPath.entryPaths.first else {
            return nil
        }

        let nestedEntryPaths = Array(authoredLayerPath.entryPaths.dropFirst())
        for candidate in candidateEntryPaths(
            for: firstAuthoredEntryPath,
            sourceEntryPath: sourceContext.sourceEntry.path,
            defaultLayerPath: sourceContext.archive.defaultLayer?.path
        ) {
            guard let candidateEntry = sourceContext.archive.entry(at: candidate) else {
                continue
            }
            if let resolvedEntryPaths = try resolve(
                candidateEntry: candidateEntry,
                nestedEntryPaths: nestedEntryPaths
            ) {
                return USDZLayerPath(entryPaths: sourceContext.prefixEntryPaths + [candidate] + resolvedEntryPaths)
            }
        }
        return nil
    }

    private func context(for layerPath: USDZLayerPath) throws -> USDZAssetResolverContext {
        guard !layerPath.entryPaths.isEmpty else {
            throw USDImportError.invalidData("USDZ layer path is empty.")
        }

        var currentArchive = archive
        var prefixEntryPaths: [String] = []
        for (index, entryPath) in layerPath.entryPaths.enumerated() {
            guard let entry = currentArchive.entry(at: entryPath) else {
                throw USDImportError.invalidData("USDZ package is missing entry \(entryPath).")
            }

            let isLastEntry = index == layerPath.entryPaths.count - 1
            if isLastEntry {
                guard entry.isUSDLayer else {
                    throw USDImportError.unsupportedFeature("USDZ entry \(entry.path) is not a USD layer.")
                }
                return USDZAssetResolverContext(
                    prefixEntryPaths: prefixEntryPaths,
                    archive: currentArchive,
                    sourceEntry: entry
                )
            }

            guard entry.fileExtension == "usdz" else {
                throw USDImportError.unsupportedFeature("USDZ entry \(entry.path) is not a nested USDZ package.")
            }
            prefixEntryPaths.append(entry.path)
            currentArchive = try USDZArchive(data: entry.data)
        }

        throw USDImportError.invalidData("USDZ layer path is empty.")
    }

    private func candidateEntryPaths(
        for assetPath: String,
        sourceEntryPath: String,
        defaultLayerPath: String?
    ) -> [String] {
        let sourceDirectory = directoryPath(for: sourceEntryPath)
        let defaultLayerDirectory = defaultLayerPath.map(directoryPath(for:)) ?? ""
        let anchoredPrefix = "./"
        let anchored = assetPath.hasPrefix(anchoredPrefix)
        let relativeAssetPath = anchored
            ? String(assetPath.dropFirst(anchoredPrefix.count))
            : assetPath

        var candidates: [String] = []
        if let sourceCandidate = joinedPath(directory: sourceDirectory, path: relativeAssetPath) {
            candidates.append(sourceCandidate)
        }
        if !anchored,
           let defaultLayerCandidate = joinedPath(directory: defaultLayerDirectory, path: relativeAssetPath),
           !candidates.contains(defaultLayerCandidate) {
            candidates.append(defaultLayerCandidate)
        }
        return candidates
    }

    private func resolve(candidateEntry: USDZArchiveEntry, nestedEntryPaths: [String]) throws -> [String]? {
        if nestedEntryPaths.isEmpty {
            if candidateEntry.isUSDLayer {
                return []
            }
            guard candidateEntry.fileExtension == "usdz" else {
                return nil
            }
            let nestedArchive = try USDZArchive(data: candidateEntry.data)
            guard let defaultLayer = nestedArchive.defaultLayer,
                  defaultLayer.isUSDLayer else {
                return nil
            }
            return [defaultLayer.path]
        }

        guard candidateEntry.fileExtension == "usdz" else {
            return nil
        }

        var currentArchive = try USDZArchive(data: candidateEntry.data)
        var resolvedEntryPaths: [String] = []
        for (index, entryPath) in nestedEntryPaths.enumerated() {
            guard let entry = currentArchive.entry(at: entryPath) else {
                return nil
            }

            let isLastEntry = index == nestedEntryPaths.count - 1
            if isLastEntry {
                guard entry.isUSDLayer else {
                    return nil
                }
                resolvedEntryPaths.append(entry.path)
                return resolvedEntryPaths
            }

            guard entry.fileExtension == "usdz" else {
                return nil
            }
            resolvedEntryPaths.append(entry.path)
            currentArchive = try USDZArchive(data: entry.data)
        }
        return nil
    }

    private func directoryPath(for path: String) -> String {
        guard let separatorIndex = path.lastIndex(of: "/") else {
            return ""
        }
        return String(path[..<separatorIndex])
    }

    private func joinedPath(directory: String, path: String) -> String? {
        let joinedPath = directory.isEmpty ? path : "\(directory)/\(path)"
        return normalizedRelativePath(joinedPath)
    }

    private func normalizedRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return nil
        }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    return nil
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else {
            return nil
        }
        return components.joined(separator: "/")
    }
}

private struct USDZAssetResolverContext: Sendable {
    var prefixEntryPaths: [String]
    var archive: USDZArchive
    var sourceEntry: USDZArchiveEntry
}
