#!/bin/bash
# Shared SwiftPM entrypoint. Never changes the host's sandbox configuration.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  build|test) SWIFTPM_COMMAND="$1"; shift ;;
  *) echo "Usage: $0 {build|test} [SwiftPM options]" >&2; exit 2 ;;
esac
command -v xcrun >/dev/null || { echo "xcrun not found; run ./script/doctor.sh for environment details." >&2; exit 1; }

OCR_CACHE_ROOT="$ROOT_DIR/.build"
mkdir -p "$OCR_CACHE_ROOT/module-cache" "$OCR_CACHE_ROOT/cache" \
  "$OCR_CACHE_ROOT/config" "$OCR_CACHE_ROOT/security" "$OCR_CACHE_ROOT/swift-sdks"
# The override also applies to compilation of Package.swift itself; -Xswiftc
# below covers package targets. These are cache destinations, not permissions.
export CLANG_MODULE_CACHE_PATH="$OCR_CACHE_ROOT/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$OCR_CACHE_ROOT/module-cache"

exec xcrun swift "$SWIFTPM_COMMAND" \
  --package-path "$ROOT_DIR" \
  --scratch-path "$OCR_CACHE_ROOT" \
  --cache-path "$OCR_CACHE_ROOT/cache" \
  --config-path "$OCR_CACHE_ROOT/config" \
  --security-path "$OCR_CACHE_ROOT/security" \
  --swift-sdks-path "$OCR_CACHE_ROOT/swift-sdks" \
  --manifest-cache local \
  -Xswiftc -module-cache-path -Xswiftc "$OCR_CACHE_ROOT/module-cache" \
  -Xcc "-fmodules-cache-path=$OCR_CACHE_ROOT/module-cache" \
  "$@"
