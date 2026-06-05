# OpenUSD Upstream Test Parity

This file tracks the OpenUSD upstream tests that are relevant to the current
pure Swift reader scope.

The goal is full parity over time, but the current package is a reader-focused
subset. Tests that require APIs not yet present in `swift-OpenUSD` are tracked
as blocked instead of silently omitted.

## Source

| Field | Value |
|---|---|
| Repository | `https://github.com/PixarAnimationStudios/OpenUSD` |
| Branch | `dev` |
| Commit | `32ef0b2d9a301167dd1016e42cf1c0f5194ef0fa` |
| Last verified | `2026-06-05` |

## Status Values

| Status | Meaning |
|---|---|
| `ported` | The upstream fixture or behavior has a Swift test in `OpenUSDTests`. |
| `partial` | A subset is covered, but upstream assertions are not fully represented. |
| `blocked` | The upstream test requires APIs or behavior outside the current reader surface. |
| `pending` | The fixture or test intent is relevant and not yet ported. |

## Reader Parity Flow

```mermaid
flowchart LR
  A["OpenUSD upstream testenv"] --> B["file-format reader tests"]
  A --> C["read-safety and corrupt asset tests"]
  A --> D["Stage, Sdf editing, schemas, plugins"]
  B --> E["Port to OpenUSDTests"]
  C --> E
  D --> F["Track as blocked until APIs exist"]
```

## Current Upstream Fixtures

| Upstream testenv | Fixture | Status | Swift coverage |
|---|---|---|---|
| `pxr/usd/usd/testenv/testUsdFileFormats` | `ascii.usd` | `partial` | `openUSDFileFormatAsciiFixtureReadsLayerSpecs`; full spec parity is blocked by the current `USDALayer` surface |
| `pxr/usd/usd/testenv/testUsdFileFormats` | `crate.usd` | `ported` | `openUSDFileFormatCrateFixtureReadsStructuralTables`, `openUSDFileFormatCrateFixtureKeepsLazyReadsStableAfterSourceDataMutation`, `openUSDFileFormatCrateFixtureReadsLayerSpecs` |
| `pxr/usd/sdf/testenv/testSdfUsdcVersioning` | `deprecated_0_7_0.usd` | `partial` | `openUSDSDFUSDCVersioningDeprecated070FixtureReadsLayer`; warning and export-upgrade assertions are blocked until diagnostic and writer APIs exist |
| `pxr/usd/sdf/testenv/testSdfUsdcInvalidPrimChildren.testenv` | `root.usdc`, `duplicate_prim_children.usdc` | `ported` | `openUSDSDFUSDCInvalidPrimChildrenFixtureThrowsTypedError`, `openUSDSDFUSDCDuplicatePrimChildrenFixtureThrowsTypedError`; `readLayer` and scene materialization both reject invalid `primChildren` |
| `pxr/usd/sdf/testenv/testSdfZipFile.testenv` | `test_reader.usdz`, `src/*` | `partial` | `openUSDSDFZipFileReaderFixtureReadsEntryInfoAndData`; writer assertions are blocked until a Swift USDZ writer API exists |
| `pxr/usd/sdf/testenv/testSdfUsdzResolver` | `test.usdz`, `src/*` | `partial` | `openUSDSDFUSDZResolverFixtureReadsEntriesAndNestedData`; `ArAsset` buffer/read/file-handle APIs are represented through archive entry data, sizes, offsets, and nested layer paths |
| `pxr/usd/sdf/testenv/testSdfParsing.testenv` | `01_empty.usda`, `203_newlines.usda`, `204_really_empty.usda` | `partial` | `openUSDSDFParsingEmptyFixturesReadLayers`; upstream export, metadata-only open, and baseline output comparisons are blocked until writer and diagnostic APIs exist |
| `pxr/usd/sdf/testenv/testSdfParsing.testenv` | `02_simple.usda`, `20_optionalsemicolons.usda`, `41_noEndingNewline.usda` | `partial` | `openUSDSDFParsingSimpleFixtureReadsDefAndOverPrimTransforms`, `openUSDSDFParsingOptionalSemicolonsFixtureReadsSublayersAndPrimTransforms`, `openUSDSDFParsingNoEndingNewlineFixtureReadsLayer`; arbitrary field/spec preservation is blocked by the current `USDALayer` surface |
| `pxr/usd/sdf/testenv/testSdfParsing.testenv` | `46_weirdStringContent.usda` | `partial` | `openUSDSDFParsingWeirdStringContentFixtureSkipsQuotedDelimiters`; escaped, single-quoted, and multiline strings are covered for delimiter scanning; string value preservation and writer parity require Sdf spec preservation |
| `pxr/usd/sdf/testenv/testSdfParsing.testenv` | `217_utf8_identifiers.usda` | `partial` | `openUSDSDFParsingUTF8IdentifiersFixtureReadsDefaultPrimAndTransforms`; UTF-8 default prim names, quoted prim paths, and transform inheritance are covered; arbitrary UTF-8 field names, custom data, property values, and writer parity require Sdf spec preservation |
| `pxr/usd/sdf/testenv/testSdfParsing.testenv` | `218_utf8_bad_identifier.usda` | `ported` | `openUSDSDFParsingUTF8BadIdentifierFixtureThrowsTypedError`; invalid UTF-8 prim identifiers are rejected with `USDImportError.invalidData` while valid `217_utf8_identifiers.usda` remains accepted |
| `pxr/usd/sdf/testenv/testSdfParsing.testenv` | `132_references.usda`, `152_payloads.usda` | `partial` | `openUSDSDFParsingReferencesFixtureReadsSupportedExternalArcs`, `openUSDSDFParsingPayloadsFixtureReadsSupportedExternalArcs`; external asset arcs, offsets, and escaped `@@` asset identifiers are covered; prim-only arcs, list-edit semantics, arc custom data, and writer parity require composition model expansion |
| `pxr/usd/usd/testenv/testUsdReadOutOfBounds` | `corrupt.usd` | `ported` | `openUSDReadOutOfBoundsFixtureThrowsTypedError` |
| `pxr/usd/usd/testenv/testUsdUsdcBugGHSA02.testenv` | `root.usdc` | `ported` | `openUSDUSDCSecurityFixtureThrowsTypedError` |
| `pxr/usd/usd/testenv/testUsdUsdzBugGHSA01.testenv` | `root.usdz` | `ported` | `openUSDUSDZSecurityFixtureThrowsTypedError` |
| `pxr/usd/usd/testenv/testUsdUsdzFileFormat` | `single_usd.usdz`, `single_usda.usdz`, `single_usdc.usdz` | `ported` | Archive default layer tests and contained layer graph tests |
| `pxr/usd/usd/testenv/testUsdUsdzFileFormat` | `anchored_refs*.usdz` | `ported` | `usdzReaderReadsAnchoredReferenceGraphsFromOpenUSDFixtures` and layer path tests |
| `pxr/usd/usd/testenv/testUsdUsdzFileFormat` | `search_refs*.usdz` | `ported` | `usdzReaderReadsSearchReferenceGraphsFromOpenUSDFixtures` and layer path tests |
| `pxr/usd/usd/testenv/testUsdUsdzFileFormat` | `nested_*refs*.usdz` | `ported` | `usdzReaderReadsNestedSubdirectoryReferenceGraphsFromOpenUSDFixtures` and specific layer path tests, including explicit nested root layer paths |
| `pxr/usd/usd/testenv/testUsdUsdzFileFormat` | `first_file_not_usd.usdz` | `ported` | Typed rejection and archive entry tests |

## Next Upstream Categories

| Priority | Upstream area | Status | Next action |
|---:|---|---|---|
| 1 | `testUsdFileFormats` Python assertions | `partial` | Port remaining load/identifier assertions that map to reader APIs. |
| 2 | `testUsdUsdzFileFormat` Python assertions | `partial` | Add tests for every currently copied package path and layer path edge. |
| 3 | `testUsdReadOutOfBounds` | `ported` | Keep checking that corrupt assets produce typed bounds-checking errors. |
| 4 | `testUsdUsdcBugGHSA02` | `ported` | Keep checking that corrupt USDC security fixtures produce typed read failures. |
| 5 | `testUsdUsdzBugGHSA01` | `ported` | Keep checking that corrupt USDZ security fixtures produce typed archive or crate failures. |
| 6 | `testSdfZipFile` reader assertions | `partial` | Keep checking file names, entry metadata, alignment, CRC, and source payload bytes. |
| 7 | `testSdfZipFile` writer assertions | `blocked` | Define a Swift USDZ writer API before porting writer, discard, alignment, and empty archive writer tests. |
| 8 | `testSdfUsdcVersioning` diagnostic and writer assertions | `blocked` | Define diagnostic warning capture and writer/export APIs before porting deprecated-version warning and export-upgrade assertions. |
| 9 | `testSdfUsdcInvalidPrimChildren` | `ported` | Keep checking that invalid child-name and duplicate-child fixtures produce typed `primChildren` errors. |
| 10 | `testSdfUsdzResolver` | `partial` | Keep checking package entry open, source bytes, sizes, absolute offsets, and nested package paths; full `ArAsset` API parity is blocked until an asset object API exists. |
| 11 | `pxr/usd/sdf/testenv` file and value parsing subset | `partial` | Continue porting USDA parsing fixtures that map to `USDAReader` and `USDLayer`; define writer, diagnostic, metadata-only, Sdf spec, and list-edit APIs for full `testSdfParsing` parity. |
| 12 | Stage composition, Sdf editing, schema, plugin, imaging tests | `blocked` | Define public APIs first, then port relevant upstream suites. |

## Completion Rules

An upstream test is not considered complete until the Swift test checks the
same reader-visible behavior against the same fixture or an explicitly recorded
equivalent fixture. Unsupported APIs must remain listed in this file until the
reader or model surface can express the behavior.
