# swift-OpenUSD

Pure Swift USD reading and authoring for platforms where the system OpenUSD
toolchain is not available, including WebAssembly.

## Modules

| Module | Responsibility |
| --- | --- |
| `OpenUSD` | Shared USD scene, mesh, transform, and Sdf data model types; USDA reader and writer; in-memory layer authoring. |
| `OpenUSDC` | Pure Swift USDC crate reader and scene materializer. |
| `OpenUSDZ` | USDZ archive reader with contained USDA/USDC layer support. |

## Verification

```sh
swift build
xcodebuild test -scheme swift-OpenUSD-Package -destination 'platform=macOS'
swift build --swift-sdk swift-6.3.1-RELEASE_wasm
```
