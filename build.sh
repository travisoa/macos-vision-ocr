#!/bin/bash
# Build a native-architecture macOS binary; installation is explicit.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=""

usage() {
  cat <<'EOF'
Usage:
  ./build.sh                       Build to ./build/ocr (does not install)
  ./build.sh --install [PATH]      Build and install atomically (default: ~/.local/bin/ocr)
  ./build.sh PATH                  Legacy explicit installation path
  ./build.sh --help                Show this help

Requires macOS and a Swift compiler with the macOS 26 SDK (Xcode 26 or newer).
Builds only the current machine architecture, with macOS 13 as deployment target.
EOF
}

case "${1:-}" in
  -h|--help)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    usage
    exit 0
    ;;
  --install)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    DEST="${2:-$HOME/.local/bin/ocr}"
    ;;
  "")
    [[ $# -eq 0 ]] || { echo "Installation path must not be empty." >&2; exit 2; }
    ;;
  -*)
    echo "Unknown build option: $1" >&2
    usage >&2
    exit 2
    ;;
  *)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    DEST="$1"
    ;;
esac

[[ "$(uname -s)" == Darwin ]] || { echo "This project requires macOS." >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found. Install Xcode Command Line Tools." >&2; exit 1; }

mkdir -p "$DIR/build/cache"
BUILD_TMP="$(mktemp "$DIR/build/.ocr-build.XXXXXX")"
INSTALL_TMP=""
cleanup() {
  [[ -z "$BUILD_TMP" ]] || rm -f "$BUILD_TMP"
  [[ -z "$INSTALL_TMP" ]] || rm -f "$INSTALL_TMP"
}
trap cleanup EXIT

swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$DIR/build/cache" \
  "$DIR/ocr.swift" "$DIR"/Sources/*.swift -o "$BUILD_TMP"
chmod 755 "$BUILD_TMP"
mv -f "$BUILD_TMP" "$DIR/build/ocr"
BUILD_TMP=""
echo "Built: $DIR/build/ocr"

if [[ -n "$DEST" ]]; then
  [[ ! -d "$DEST" ]] || { echo "Installation path is a directory: $DEST" >&2; exit 2; }
  mkdir -p "$(dirname "$DEST")"
  INSTALL_TMP="$(mktemp "$(dirname "$DEST")/.ocr-install.XXXXXX")"
  cp "$DIR/build/ocr" "$INSTALL_TMP"
  chmod 755 "$INSTALL_TMP"
  mv -f "$INSTALL_TMP" "$DEST"
  INSTALL_TMP=""
  echo "Installed: $DEST"
fi
