#!/bin/bash
# Deterministic regression checks: no OCR model execution, installation, or downloads.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 0 ]]; then
  echo 'Usage: ./Tests/run.sh' >&2
  echo 'For a focused native test use: ./script/swiftpm.sh test --filter TEST_NAME' >&2
  exit 2
fi

"$DIR/script/swiftpm.sh" test

if [[ -z "${OCR_BINARY:-}" ]]; then
  OCR_TEST_BIN_DIR="$("$DIR/script/swiftpm.sh" build --show-bin-path)"
  OCR_BINARY="$OCR_TEST_BIN_DIR/ocr"
fi

[[ -x "$OCR_BINARY" ]] || { echo "CLI test binary not executable: $OCR_BINARY" >&2; exit 1; }
python3 "$DIR/Tests/cli_tests.py" "$OCR_BINARY"
