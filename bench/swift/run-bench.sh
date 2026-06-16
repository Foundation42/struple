#!/bin/sh
# Compile the Struple sources + the Swift benchmark with swiftc -O and run it.
# Mirrors swift/run-tests.sh's toolchain env exactly (SwiftPM is broken on this
# host; we drive swiftc directly). Run from the repo root or anywhere — the
# benchmark resolves bench/ paths from the current working directory, so this
# script cd's to the repo root before running.
set -e

# Resolve repo root (this script lives at bench/swift/run-bench.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SWIFTC="${SWIFTC:-$HOME/swift/usr/bin/swiftc}"
SWIFT_USR="$(dirname "$(dirname "$SWIFTC")")"
[ -d "$SWIFT_USR/lib/swift/linux" ] && export LD_LIBRARY_PATH="$SWIFT_USR/lib/swift/linux:$LD_LIBRARY_PATH"
[ -d "$SWIFT_USR/bin" ] && export PATH="$SWIFT_USR/bin:$PATH"
[ -d "$HOME/swift-shims" ] && export LD_LIBRARY_PATH="$HOME/swift-shims:$LD_LIBRARY_PATH"

mkdir -p "$SCRIPT_DIR/build"
"$SWIFTC" -O \
  "$SCRIPT_DIR/main.swift" \
  "$REPO_ROOT/swift/Sources/Struple/Struple.swift" \
  -o "$SCRIPT_DIR/build/struple-bench"

cd "$REPO_ROOT"
exec "$SCRIPT_DIR/build/struple-bench"
