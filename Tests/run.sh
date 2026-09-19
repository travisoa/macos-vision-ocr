#!/bin/bash
# Deterministic regression checks: no OCR model execution, installation, or downloads.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ocr-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

if [[ -z "${OCR_BINARY:-}" ]]; then
  "$DIR/build.sh"
  OCR_BINARY="$DIR/build/ocr"
fi

swiftc -parse-as-library \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$TEST_DIR/cache" \
  "$DIR"/Sources/*.swift "$DIR"/Tests/*.swift -o "$TEST_DIR/unit-tests"
"$TEST_DIR/unit-tests"
python3 "$DIR/Tests/cli_tests.py" "$OCR_BINARY"
