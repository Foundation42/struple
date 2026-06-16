#!/bin/sh
# Compile all sources + tests and run the plain main() conformance runners.
# Each runner reads ../conformance/*.json (CWD = java/), prints a summary, and
# exits nonzero on any failure — mirroring c/test_conformance.c. Zero infra:
# no Maven/Gradle, no JUnit. Requires javac/java 26 on PATH.
set -e

cd "$(dirname "$0")"

mkdir -p build
javac -d build $(find src test -name '*.java')

java -cp build struple.TestConformance
java -cp build struple.TestStruple
