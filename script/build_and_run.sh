#!/bin/bash
# A short-lived CLI needs no global kill/relaunch or persistent PID record.
# exec makes the launched OCR/debugger replace this script, preserving signals
# and exit status without touching OCR jobs started by another caller.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE=run
CONFIGURATION=debug

usage() {
  cat <<'EOF'
Usage:
  ./script/build_and_run.sh                         Build debug OCR, then show its help
  ./script/build_and_run.sh -- <OCR arguments...>    Build and run OCR with exact arguments
  ./script/build_and_run.sh --verify                Build and verify OCR exits successfully with --version
  ./script/build_and_run.sh --debug -- <args...>     Build debug OCR, then open LLDB with exact arguments
  ./script/build_and_run.sh --release -- <args...>   Build and run optimized OCR

Build diagnostics go to stderr; stdout belongs to OCR. No other OCR process is
stopped. The script becomes its own OCR/debugger process via exec; normal signals
and exit status are preserved. There is no daemon or cross-run PID management.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --verify|--debug)
      [[ "$MODE" == run ]] || { echo "Choose either --verify or --debug." >&2; exit 2; }
      MODE="${1#--}"
      shift
      ;;
    --release) CONFIGURATION=release; shift ;;
    --) shift; break ;;
    *) echo "Unknown run option: $1 (place OCR arguments after --)." >&2; exit 2 ;;
  esac
done
if [[ "$MODE" == verify && $# -gt 0 ]]; then
  echo "--verify uses --version and does not accept OCR arguments." >&2
  exit 2
fi
if [[ "$MODE" == debug && "$CONFIGURATION" == release ]]; then
  echo "--debug launches LLDB using a debug build; omit --release." >&2
  exit 2
fi

"$ROOT_DIR/build.sh" "--$CONFIGURATION" >&2
# build/ocr is a compatibility staging path shared by debug/release builds.
# Launch this invocation's configuration directly, even if another build later
# replaces the staged copy.
BIN_DIR="$("$ROOT_DIR/script/swiftpm.sh" build -c "$CONFIGURATION" --show-bin-path)"
OCR_BINARY="$BIN_DIR/ocr"
if [[ "$MODE" == verify ]]; then
  exec "$OCR_BINARY" --version
fi
if [[ $# -eq 0 ]]; then set -- --help; fi
if [[ "$MODE" == debug ]]; then
  exec xcrun lldb -- "$OCR_BINARY" "$@"
fi
exec "$OCR_BINARY" "$@"
