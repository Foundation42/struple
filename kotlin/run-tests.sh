#!/bin/sh
# Compile all struple sources + tests into one runtime jar, then run the two
# plain-main() conformance/behavioral runners. Each exits nonzero on any failure,
# and `set -e` makes this script propagate that. Zero infra: no Gradle, no JUnit.
#
# Run from the kotlin/ directory (CWD must be kotlin/ so ../conformance resolves).
set -e

KOTLINC="${KOTLINC:-$HOME/kotlin-dist/kotlinc/bin/kotlinc}"

mkdir -p build
"$KOTLINC" src/*.kt test/*.kt -include-runtime -d build/struple-tests.jar

java -cp build/struple-tests.jar TestConformanceKt
java -cp build/struple-tests.jar TestStrupleKt
