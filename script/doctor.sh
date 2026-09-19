#!/bin/bash
# Read-only environment and executable diagnostics. No builds or OCR execution.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
OCR_DOCTOR_OS_VERSION=""
OCR_DOCTOR_SWIFT_VERSION=""
OCR_DOCTOR_SDK_VERSION=""

report() {
  local label="$1"
  shift
  printf '\n%s\n' "$label"
  if ! "$@"; then FAILED=1; fi
}

capture_report() {
  local variable="$1"
  local label="$2"
  local output=""
  shift 2
  printf '\n%s\n' "$label"
  if output="$("$@")"; then
    printf '%s\n' "$output"
    printf -v "$variable" '%s' "$output"
  else
    printf '%s\n' "$output"
    FAILED=1
  fi
}

check_major_version() {
  local label="$1"
  local version="$2"
  local minimum="$3"
  local major="${version%%.*}"
  case "$major" in
    ''|*[!0-9]*) echo "Cannot determine $label version: $version" >&2; FAILED=1 ;;
    *)
      if (( 10#$major < minimum )); then
        echo "$label $version is too old; requires $minimum or newer." >&2
        FAILED=1
      fi
      ;;
  esac
}

printf 'macos-vision-ocr environment\nProject: %s\n' "$ROOT_DIR"
capture_report OCR_DOCTOR_OS_VERSION 'macOS version (requires 13+):' /usr/bin/sw_vers -productVersion
report 'macOS build:' /usr/bin/sw_vers -buildVersion
report 'Architecture:' /usr/bin/uname -m
report 'Active developer directory:' /usr/bin/xcode-select -p
report 'Swift tool:' /usr/bin/xcrun --find swift
report 'Swift compiler:' /usr/bin/xcrun --find swiftc
capture_report OCR_DOCTOR_SWIFT_VERSION 'Swift version (requires 6.2+):' /usr/bin/xcrun swift --version
report 'macOS SDK path:' /usr/bin/xcrun --sdk macosx --show-sdk-path
capture_report OCR_DOCTOR_SDK_VERSION 'macOS SDK version (requires 26+):' /usr/bin/xcrun --sdk macosx --show-sdk-version
report 'LLDB for optional --debug:' /usr/bin/xcrun --find lldb

check_major_version 'macOS' "$OCR_DOCTOR_OS_VERSION" 13
check_major_version 'macOS SDK' "$OCR_DOCTOR_SDK_VERSION" 26
if [[ "$OCR_DOCTOR_SWIFT_VERSION" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
  if (( 10#${BASH_REMATCH[1]} < 6 || (10#${BASH_REMATCH[1]} == 6 && 10#${BASH_REMATCH[2]} < 2) )); then
    echo "Swift is too old; requires Swift 6.2 or newer." >&2
    FAILED=1
  fi
else
  echo "Cannot determine Swift version; requires Swift 6.2 or newer." >&2
  FAILED=1
fi

printf '\nExecutable metadata (no executable is run):\n'
FOUND=false
for candidate in "$ROOT_DIR/build/ocr" "$ROOT_DIR"/.build/*/debug/ocr "$ROOT_DIR"/.build/*/release/ocr; do
  if [[ -f "$candidate" ]]; then
    FOUND=true
    /usr/bin/file "$candidate"
    /bin/ls -l "$candidate"
  fi
done
if [[ "$FOUND" == false ]]; then printf 'No project build found.\n'; fi
if INSTALLED_OCR="$(command -v ocr 2>/dev/null)"; then
  printf '\nOCR currently on PATH: %s\n' "$INSTALLED_OCR"
  if [[ -f "$INSTALLED_OCR" ]]; then /usr/bin/file "$INSTALLED_OCR"; fi
else
  printf '\nNo OCR command on PATH.\n'
fi
printf '\nProject-local SwiftPM cache: %s/.build\n' "$ROOT_DIR"
printf 'Ordinary OCR: macOS 13+; experimental document tables: macOS 26+.\n'
exit "$FAILED"
