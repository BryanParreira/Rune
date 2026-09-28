#!/bin/sh
# Opens Rune with a new tab in the given directory (default: the current directory).
# Usage: rune [directory]
set -e

target="${1:-$PWD}"
if [ ! -d "$target" ]; then
  echo "rune: not a directory: $target" >&2
  exit 1
fi
dir=$(cd "$target" && pwd -P)

# Prefer the bundle id so it works wherever Rune.app is installed.
if open -b dev.rune.Rune "$dir" 2>/dev/null; then
  exit 0
fi
exec open -a Rune "$dir"
