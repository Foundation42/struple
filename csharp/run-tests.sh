#!/bin/sh
# Build and run the C# struple conformance + behavioral suite.
# Exits nonzero on any failure (like the C/C++/Java ports).
# CWD must be csharp/ so the corpus resolves at ../conformance/*.json.
set -e
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
"$DOTNET" run -c Release --project test
