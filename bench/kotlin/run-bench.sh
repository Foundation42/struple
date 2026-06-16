#!/bin/sh
# Compile the struple Kotlin codec + this benchmark into one runtime jar, then
# run it on the JVM. Zero infra: no Gradle, no JUnit — same style as
# kotlin/run-tests.sh, and it reuses the same KOTLINC env var / default path.
#
# Run from the repo root (the parent of bench/) so the data + manifest paths
# resolve; the bench also walks up from its CWD to find bench/payloads.json, so
# it is robust to being launched elsewhere.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

KOTLINC="${KOTLINC:-$HOME/kotlin-dist/kotlinc/bin/kotlinc}"

"$KOTLINC" kotlin/src/Struple.kt bench/kotlin/Bench.kt \
    -include-runtime -d bench/kotlin/bench.jar

java -cp bench/kotlin/bench.jar BenchKt "$REPO_ROOT"
