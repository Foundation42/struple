#!/bin/sh
set -e
cd "$(dirname "$0")"
DART="${DART:-$HOME/dart-sdk/bin/dart}"
"$DART" pub get   # resolve the (dependency-free) package so `dart run` works on a fresh checkout
"$DART" run bin/test_conformance.dart
"$DART" run bin/test_struple.dart
