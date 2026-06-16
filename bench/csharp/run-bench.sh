#!/bin/sh
# Build (Release) and run the C# struple encode/decode benchmark.
# Reads ../payloads.json + ../data/<name>.json, verifies sha256 byte-identity,
# benchmarks encode + decode, and writes ../results/csharp.json.
#
# Run from anywhere:  bench/csharp/run-bench.sh
set -e
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
HERE="$(cd "$(dirname "$0")" && pwd)"
"$DOTNET" run -c Release --project "$HERE/Bench.csproj"
