#!/usr/bin/env python3
import argparse
import json
import platform
import sys
from pathlib import Path


SYMBOLGRAPH_DIR_TEMPLATE = ".build/{arch}-apple-macosx/symbolgraph"

SWIFT_ARCH_BY_MACHINE = {
    "arm64": "arm64",
    "x86_64": "x86_64",
}


def default_symbolgraph_dir() -> str:
    machine = platform.machine()
    arch = SWIFT_ARCH_BY_MACHINE.get(machine)
    if arch is None:
        raise RuntimeError(
            f"Unsupported host architecture {machine!r}; expected one of "
            f"{sorted(SWIFT_ARCH_BY_MACHINE)}. Pass --symbolgraph-dir explicitly."
        )
    return SYMBOLGRAPH_DIR_TEMPLATE.format(arch=arch)


REMOVED_PUBLIC_SYMBOLS = {
    "SdfSpecifier.init(cratePayload:)",
    "USDTransformMatrix4x4.validatedConcatenating(_:)",
    "USDTransformMatrix4x4.transformNormal(_:)",
    "USDZArchive.assetData(for:)",
    "USDZArchive.data(for:)",
    "USDZArchive.data(for:referencedFrom:)",
}

REQUIRED_PUBLIC_SYMBOLS = {
    "SdfFieldValue",
    "SdfFieldValue.authored(_:)",
    "SdfFieldValue.pathListOperation(_:)",
    "SdfFieldValue.toUSDLayerFieldValue()",
    "SdfLayer",
    "SdfLayer.clear()",
    "SdfLayer.exportUSDA()",
    "SdfLayer.field(named:at:)",
    "SdfLayer.importUSDA(from:identifier:)",
    "SdfLayer.init(usdLayer:identifier:)",
    "SdfLayer.listFields(at:)",
    "SdfLayer.setField(_:for:at:)",
    "SdfLayer.spec(at:)",
    "SdfLayer.toUSDALayer()",
    "SdfPath",
    "SdfPath.Kind.propertyTarget",
    "SdfPath.absoluteRoot",
    "SdfPath.appendingChild(_:)",
    "SdfPath.appendingProperty(_:)",
    "SdfPath.init(_:)",
    "SdfPath.kind",
    "SdfPath.rawValue",
    "SdfSpec",
    "SdfSpec.clearField(named:)",
    "SdfSpec.field(named:)",
    "SdfSpec.init(layerSpec:)",
    "SdfSpec.listFields()",
    "SdfSpec.setField(_:for:)",
    "SdfSpec.toUSDLayerSpec()",
    "USDAttribute",
    "USDGeomMesh.define(in:at:)",
    "USDGeomMesh.setTopology(points:faceVertexCounts:faceVertexIndices:in:)",
    "USDGeomXform.define(in:at:)",
    "USDGeomXform.setTranslate(_:in:)",
    "USDPrim",
    "USDRelationship",
    "USDStage.createAttribute(at:name:typeName:defaultValue:variability:custom:)",
    "USDStage.createInMemory(defaultPrim:metersPerUnit:upAxis:)",
    "USDStage.createRelationship(at:name:targetPaths:custom:)",
    "USDStage.definePrim(at:typeName:)",
    "USDStage.exportSdfLayer()",
    "USDStage.exportUSDA()",
    "USDStage.init(rootLayer:)",
    "USDTransformMatrix4x4.concatenating(_:)",
    "USDTransformMatrix4x4.transform(normal:)",
    "SdfListOperation",
    "SdfListOperation.effectiveItems",
    "SdfListOperation.isEmpty",
    "USDLayerFieldValue.authored(_:)",
    "USDLayerFieldValue.pathListOperation(_:)",
    "USDLayerSpec.fields",
    "USDAWriter.data(for:)",
    "USDAWriter.string(for:)",
    "USDPlugin",
    "USDPlugin.declaredTypeNames",
    "USDPlugin.metadata(forType:)",
    "USDPluginRegistry",
    "USDPluginRegistry.declaredTypeNames",
    "USDPluginRegistry.plugin(named:)",
    "USDPluginRegistry.pluginsDeclaring(typeName:)",
    "USDPluginRegistry.registerPlugInfo(at:)",
    "USDPluginRegistry.registerPlugInfo(from:)",
    "USDPluginMetadataValue",
    "USDPluginType",
    "USDPrim.isA(_:registry:)",
    "USDPrimDefinition",
    "USDPrimDefinition.apiSchemaPropertyNamespacePrefix",
    "USDPrimDefinition.merging(_:)",
    "USDSchemaKind",
    "USDSchemaKind.isAppliedAPI",
    "USDSchemaKind.isConcrete",
    "USDSchemaRegistry",
    "USDSchemaRegistry.composedDefinition(primType:appliedAPISchemas:)",
    "USDSchemaRegistry.definition(for:)",
    "USDSchemaRegistry.isA(_:_:)",
    "USDSchemaRegistry.isAppliedAPISchema(_:)",
    "USDSchemaRegistry.register(plugin:)",
    "USDCUnmaterializedValue",
    "USDCLayerFieldValue.unmaterializedValue(_:)",
    "USDZArchive.assetData(at:)",
    "USDZArchive.layerData(at:)",
    "USDZArchive.layerData(for:referencedFrom:)",
}

FORBIDDEN_PUBLIC_SYMBOL_PREFIXES = {
    "USDCCrate",
    "USDCPrimSpecifier",
}

FORBIDDEN_PUBLIC_SYMBOLS = {
    "USDCReader.readCrate(from:)",
}

FORBIDDEN_PUBLIC_SYMBOL_SUBSTRINGS = {
    "cratePayload",
    "readCrate",
}


def public_symbol_names(symbol_graph_dir: Path) -> set[str]:
    files = sorted(symbol_graph_dir.rglob("*.symbols.json"))
    if not files:
        raise RuntimeError(
            f"No symbol graph files found under {symbol_graph_dir}. "
            "Run `swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members` first."
        )

    names: set[str] = set()
    for file in files:
        with file.open(encoding="utf-8") as handle:
            document = json.load(handle)
        for symbol in document.get("symbols", []):
            if symbol.get("accessLevel") != "public":
                continue
            path_components = symbol.get("pathComponents", [])
            if path_components:
                names.add(".".join(path_components))
    return names


def forbidden_public_symbols(names: set[str]) -> list[str]:
    forbidden: list[str] = []
    for name in sorted(names):
        components = name.split(".")
        if name in FORBIDDEN_PUBLIC_SYMBOLS:
            forbidden.append(name)
            continue
        if any(substring in name for substring in FORBIDDEN_PUBLIC_SYMBOL_SUBSTRINGS):
            forbidden.append(name)
            continue
        if any(
            component.startswith(prefix)
            for component in components
            for prefix in FORBIDDEN_PUBLIC_SYMBOL_PREFIXES
        ):
            forbidden.append(name)
    return forbidden


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the public API symbol contract.")
    parser.add_argument(
        "--symbolgraph-dir",
        default=None,
        help=(
            "Directory containing Swift symbol graph JSON files. "
            f"Defaults to {SYMBOLGRAPH_DIR_TEMPLATE!r} with the detected host architecture."
        ),
    )
    args = parser.parse_args()

    try:
        symbol_graph_dir = Path(args.symbolgraph_dir or default_symbolgraph_dir())
        names = public_symbol_names(symbol_graph_dir)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    removed = sorted(REMOVED_PUBLIC_SYMBOLS.intersection(names))
    missing = sorted(REQUIRED_PUBLIC_SYMBOLS.difference(names))
    forbidden = forbidden_public_symbols(names)

    if removed:
        print("Removed public API symbols are still present:", file=sys.stderr)
        for name in removed:
            print(f"  - {name}", file=sys.stderr)
    if missing:
        print("Required public API symbols are missing:", file=sys.stderr)
        for name in missing:
            print(f"  - {name}", file=sys.stderr)
    if forbidden:
        print("Forbidden implementation-detail symbols are public:", file=sys.stderr)
        for name in forbidden:
            print(f"  - {name}", file=sys.stderr)
    if removed or missing or forbidden:
        return 1

    print(f"Verified {len(names)} public symbols.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
