#!/bin/sh
# Compiles the pure Swift in ios/Core with its tests for macOS, and runs it.
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/rnck-swift-tests"
xcrun swiftc -O -o "$OUT" ios/Core/*.swift ios/Tests/main.swift
"$OUT"
