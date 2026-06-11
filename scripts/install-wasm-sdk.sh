#!/usr/bin/env bash
set -euo pipefail

sdk_id="${SWIFT_WASM_SDK_ID:-swift-6.3.1-RELEASE_wasm}"
sdk_url="${SWIFT_WASM_SDK_URL:-https://download.swift.org/swift-6.3.1-release/wasm-sdk/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE_wasm.artifactbundle.tar.gz}"
sdk_checksum="${SWIFT_WASM_SDK_CHECKSUM:-bd47baa20771f366d8beed7970afaa30742b2210097afd15f85427226d8f4cf2}"

if swift sdk list | grep -Fqx "${sdk_id}"; then
    echo "Swift Wasm SDK ${sdk_id} is already installed."
else
    swift sdk install "${sdk_url}" --checksum "${sdk_checksum}"
fi

swift sdk list | grep -Fqx "${sdk_id}"
echo "Swift Wasm SDK ${sdk_id} is ready."
