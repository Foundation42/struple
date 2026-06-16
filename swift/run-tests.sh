#!/bin/sh
# Compile the Struple sources + the conformance/behavior runner with swiftc and
# run it. Prints a summary; exits nonzero on any failure.
#
# SwiftPM (`swift build`/`swift test`) is broken on this host (missing
# libxml2.so.2), so we drive swiftc directly. The runner reads ../conformance/*.json,
# so run from the swift/ directory (this script cd's there itself).
set -e

cd "$(dirname "$0")"

SWIFTC="${SWIFTC:-$HOME/swift/usr/bin/swiftc}"
# Always expose the toolchain's Swift runtime libs (needed to run the binary),
# derived from the compiler location; add the bin dir to PATH; and, on hosts that
# need them (e.g. Arch), the local ncurses shims.
SWIFT_USR="$(dirname "$(dirname "$SWIFTC")")"
[ -d "$SWIFT_USR/lib/swift/linux" ] && export LD_LIBRARY_PATH="$SWIFT_USR/lib/swift/linux:$LD_LIBRARY_PATH"
[ -d "$SWIFT_USR/bin" ] && export PATH="$SWIFT_USR/bin:$PATH"
[ -d "$HOME/swift-shims" ] && export LD_LIBRARY_PATH="$HOME/swift-shims:$LD_LIBRARY_PATH"

mkdir -p build
"$SWIFTC" -O Sources/Struple/*.swift Tests/*.swift -o build/struple-tests
./build/struple-tests
