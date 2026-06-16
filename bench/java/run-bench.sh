#!/bin/sh
# Compile and run the struple Java benchmark. Zero infra: no Maven/Gradle/JUnit,
# matching the port's no-build-tool style. Requires javac/java 26 on PATH (the
# same toolchain java/run-tests.sh uses). Run from the repo root (paths to
# bench/data, bench/payloads.json, bench/results resolve relative to CWD).
#
#   sh bench/java/run-bench.sh
#
# Builds Bench (default package) + the struple codec into bench/java/build, then
# runs it with the repo root as CWD so the bench/* paths resolve.
set -e

# Resolve repo root from this script's location, then cd there.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

mkdir -p bench/java/build
javac -d bench/java/build bench/java/Bench.java java/src/struple/Struple.java

java -cp bench/java/build Bench
