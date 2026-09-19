#!/bin/bash
# Incremental SwiftPM build; staging and installation replace only complete files.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=""
CONFIGURATION=""
INSTALL_REQUESTED=false

usage() {
  cat <<'EOF'
Usage:
  ./build.sh                         Incremental debug build, staged to ./build/ocr
  ./build.sh --release                Optimized release build
  ./build.sh --install [PATH]         Release build and atomic install (default: ~/.local/bin/ocr)
  ./build.sh --debug --install [PATH] Explicitly install a debug build
  ./build.sh PATH                     Legacy explicit installation path (release)
  ./build.sh --help                   Show this help

--debug and --release are mutually exclusive. No-argument builds do not install.
Requires Swift 6.2+ and the macOS 26+ SDK. Deployment target: macOS 13.
Builds only the current machine architecture; SwiftPM caches stay in .build/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --debug|--release)
      NEXT_CONFIGURATION="${1#--}"
      if [[ -n "$CONFIGURATION" && "$CONFIGURATION" != "$NEXT_CONFIGURATION" ]]; then
        echo "--debug and --release are mutually exclusive." >&2
        exit 2
      fi
      CONFIGURATION="$NEXT_CONFIGURATION"
      ;;
    --install)
      [[ "$INSTALL_REQUESTED" == false ]] || { echo "Installation destination specified more than once." >&2; exit 2; }
      INSTALL_REQUESTED=true
      DEST="$HOME/.local/bin/ocr"
      if [[ $# -gt 1 && "${2:0:1}" != "-" ]]; then
        [[ -n "$2" ]] || { echo "Installation path must not be empty." >&2; exit 2; }
        DEST="$2"
        shift
      fi
      ;;
    -*) echo "Unknown build option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -n "$1" ]] || { echo "Installation path must not be empty." >&2; exit 2; }
      [[ "$INSTALL_REQUESTED" == false ]] || { echo "Installation destination specified more than once." >&2; exit 2; }
      INSTALL_REQUESTED=true
      DEST="$1"
      ;;
  esac
  shift
done

[[ "$(uname -s)" == Darwin ]] || { echo "This project requires macOS." >&2; exit 1; }
if [[ -z "$CONFIGURATION" ]]; then
  if [[ "$INSTALL_REQUESTED" == true ]]; then CONFIGURATION=release; else CONFIGURATION=debug; fi
fi
[[ -z "$DEST" || ! -d "$DEST" ]] || { echo "Installation path is a directory: $DEST" >&2; exit 2; }

BUILD_TMP=""
INSTALL_TMP=""
cleanup() {
  [[ -z "$BUILD_TMP" ]] || rm -f "$BUILD_TMP"
  [[ -z "$INSTALL_TMP" ]] || rm -f "$INSTALL_TMP"
}
trap cleanup EXIT

"$DIR/script/swiftpm.sh" build -c "$CONFIGURATION" --product ocr >&2
BIN_DIR="$("$DIR/script/swiftpm.sh" build -c "$CONFIGURATION" --show-bin-path)"
[[ -x "$BIN_DIR/ocr" ]] || { echo "Built OCR executable is missing: $BIN_DIR/ocr" >&2; exit 1; }
mkdir -p "$DIR/build"
[[ ! -d "$DIR/build/ocr" ]] || { echo "Staging path is a directory: $DIR/build/ocr" >&2; exit 1; }
BUILD_TMP="$(mktemp "$DIR/build/.ocr-build.XXXXXX")"
cp "$BIN_DIR/ocr" "$BUILD_TMP"
chmod 755 "$BUILD_TMP"
mv -f "$BUILD_TMP" "$DIR/build/ocr"
BUILD_TMP=""
echo "Built ($CONFIGURATION): $DIR/build/ocr" >&2

if [[ -n "$DEST" ]]; then
  mkdir -p "$(dirname "$DEST")"
  INSTALL_TMP="$(mktemp "$(dirname "$DEST")/.ocr-install.XXXXXX")"
  cp "$BIN_DIR/ocr" "$INSTALL_TMP"
  chmod 755 "$INSTALL_TMP"
  mv -f "$INSTALL_TMP" "$DEST"
  INSTALL_TMP=""
  echo "Installed ($CONFIGURATION): $DEST" >&2
fi
