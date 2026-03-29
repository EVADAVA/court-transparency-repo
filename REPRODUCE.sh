#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/video_tools_bin"
SRC1="${1:-}"
SRC2="${2:-}"
OUT="${3:-$ROOT/combined_call_2026-03-22.mov}"

if [[ -z "$SRC1" || -z "$SRC2" ]]; then
  echo "Usage: ./REPRODUCE.sh <source1.mov> <source2.mov> [output.mov]" >&2
  exit 1
fi

swiftc -parse-as-library "$ROOT/scripts/video_tools.swift" -o "$BIN"

"$BIN" join "$OUT" "$SRC1" "$SRC2"
"$BIN" analyze "$SRC1" "$SRC2"

echo
echo "SHA-256:"
shasum -a 256 "$SRC1" "$SRC2" "$OUT"
