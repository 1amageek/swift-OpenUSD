import OpenUSD

/// Builds synthetic USDA sources and in-memory layer stacks sized for
/// benchmarking. Sources are assembled line by line so prim counts scale
/// without quadratic string copying.
enum SyntheticUSDASource {

    /// A root `Xform` containing `primCount` child `Xform` prims, each with a
    /// translate op, exercising prim, attribute, and metadata parsing.
    static func flatXformHierarchy(primCount: Int) -> String {
        var lines: [String] = [
            "#usda 1.0",
            "(",
            "    defaultPrim = \"Root\"",
            "    metersPerUnit = 1",
            "    upAxis = \"Y\"",
            ")",
            "",
            "def Xform \"Root\"",
            "{",
        ]
        lines.reserveCapacity(lines.count + primCount * 6 + 1)
        for index in 0..<primCount {
            lines.append("    def Xform \"Prim\(index)\"")
            lines.append("    {")
            lines.append("        double3 xformOp:translate = (\(index), 0, 0)")
            lines.append("        uniform token[] xformOpOrder = [\"xformOp:translate\"]")
            lines.append("    }")
            lines.append("")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// A root `Xform` containing `meshCount` two-triangle meshes, exercising
    /// array value parsing and scene materialization.
    static func meshScene(meshCount: Int) -> String {
        var lines: [String] = [
            "#usda 1.0",
            "(",
            "    defaultPrim = \"Root\"",
            "    metersPerUnit = 1",
            "    upAxis = \"Y\"",
            ")",
            "",
            "def Xform \"Root\"",
            "{",
        ]
        lines.reserveCapacity(lines.count + meshCount * 8 + 1)
        for index in 0..<meshCount {
            lines.append("    def Mesh \"Mesh\(index)\"")
            lines.append("    {")
            lines.append("        point3f[] points = [(\(index), 0, 0), (\(index + 1), 0, 0), (\(index), 1, 0), (\(index + 1), 1, 0)]")
            lines.append("        int[] faceVertexCounts = [3, 3]")
            lines.append("        int[] faceVertexIndices = [0, 1, 2, 1, 3, 2]")
            lines.append("        uniform token subdivisionScheme = \"none\"")
            lines.append("    }")
            lines.append("")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// A root layer with `sublayerCount` sublayers, each contributing
    /// `primsPerSublayer` prims under `/Root`, for flattening benchmarks.
    static func sublayerStack(
        sublayerCount: Int,
        primsPerSublayer: Int
    ) throws -> (rootLayer: USDALayer, provider: USDInMemoryLayerProvider) {
        let reader = USDAReader()
        var layers: [String: SdfLayer] = [:]
        var sublayerReferences: [String] = []
        for layerIndex in 0..<sublayerCount {
            let identifier = "layer\(layerIndex).usda"
            sublayerReferences.append("        @\(identifier)@,")
            var lines: [String] = [
                "#usda 1.0",
                "",
                "over \"Root\"",
                "{",
            ]
            for primIndex in 0..<primsPerSublayer {
                lines.append("    def Xform \"Layer\(layerIndex)Prim\(primIndex)\"")
                lines.append("    {")
                lines.append("        double3 xformOp:translate = (\(primIndex), \(layerIndex), 0)")
                lines.append("        uniform token[] xformOpOrder = [\"xformOp:translate\"]")
                lines.append("    }")
            }
            lines.append("}")
            layers[identifier] = try SdfLayer(
                usdLayer: reader.readLayer(from: lines.joined(separator: "\n")),
                identifier: identifier
            )
        }
        let rootLines: [String] = [
            "#usda 1.0",
            "(",
            "    defaultPrim = \"Root\"",
            "    subLayers = [",
        ] + sublayerReferences + [
            "    ]",
            ")",
            "",
            "def Xform \"Root\"",
            "{",
            "}",
        ]
        let rootLayer = try reader.readLayer(from: rootLines.joined(separator: "\n"))
        return (rootLayer, USDInMemoryLayerProvider(layers: layers))
    }

    /// A root layer with `referenceCount` prims that each reference the same
    /// mesh-bearing target layer, for reference-arc flattening benchmarks.
    static func referenceForest(
        referenceCount: Int
    ) throws -> (rootLayer: USDALayer, provider: USDInMemoryLayerProvider) {
        let reader = USDAReader()
        let targetLines: [String] = [
            "#usda 1.0",
            "(",
            "    defaultPrim = \"Target\"",
            ")",
            "",
            "def Xform \"Target\"",
            "{",
            "    def Mesh \"Geom\"",
            "    {",
            "        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]",
            "        int[] faceVertexCounts = [3]",
            "        int[] faceVertexIndices = [0, 1, 2]",
            "        uniform token subdivisionScheme = \"none\"",
            "    }",
            "}",
        ]
        let targetLayer = try reader.readLayer(from: targetLines.joined(separator: "\n"))
        var rootLines: [String] = [
            "#usda 1.0",
            "(",
            "    defaultPrim = \"Root\"",
            ")",
            "",
            "def Xform \"Root\"",
            "{",
        ]
        rootLines.reserveCapacity(rootLines.count + referenceCount * 6 + 1)
        for index in 0..<referenceCount {
            rootLines.append("    def Xform \"Ref\(index)\" (")
            rootLines.append("        references = @target.usda@</Target>")
            rootLines.append("    )")
            rootLines.append("    {")
            rootLines.append("    }")
            rootLines.append("")
        }
        rootLines.append("}")
        let rootLayer = try reader.readLayer(from: rootLines.joined(separator: "\n"))
        let provider = USDInMemoryLayerProvider(layers: [
            "target.usda": try SdfLayer(usdLayer: targetLayer, identifier: "target.usda"),
        ])
        return (rootLayer, provider)
    }
}
