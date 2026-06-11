import OpenUSD

struct USDZLayerPath: Sendable, Equatable {
    var entryPaths: [String]

    var stringValue: String {
        guard let firstEntryPath = entryPaths.first else {
            return ""
        }
        return entryPaths.dropFirst().reduce(firstEntryPath) { partialPath, entryPath in
            "\(partialPath)[\(entryPath)]"
        }
    }

    static func parse(_ text: String) throws -> USDZLayerPath {
        var cursor = text.startIndex
        let entryPaths = try parseEntryPaths(in: text, cursor: &cursor)
        guard cursor == text.endIndex else {
            throw USDError.invalidData("USDZ layer path has trailing characters.")
        }
        return USDZLayerPath(entryPaths: entryPaths)
    }

    private static func parseEntryPaths(in text: String, cursor: inout String.Index) throws -> [String] {
        let entryStart = cursor
        while cursor < text.endIndex, text[cursor] != "[", text[cursor] != "]" {
            cursor = text.index(after: cursor)
        }
        guard entryStart < cursor else {
            throw USDError.invalidData("USDZ layer path is missing an entry path.")
        }
        var entryPaths = [String(text[entryStart..<cursor])]
        if cursor < text.endIndex, text[cursor] == "[" {
            cursor = text.index(after: cursor)
            entryPaths.append(contentsOf: try parseEntryPaths(in: text, cursor: &cursor))
            guard cursor < text.endIndex, text[cursor] == "]" else {
                throw USDError.invalidData("USDZ layer path has an unterminated nested path.")
            }
            cursor = text.index(after: cursor)
        }
        return entryPaths
    }
}
