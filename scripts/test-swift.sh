#!/bin/sh
# Compiles the pure Swift in ios/Core and the store with its tests for macOS, and runs it.
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/rnck-swift-tests"
xcrun swiftc -O -lsqlite3 -o "$OUT" ios/Core/*.swift ios/Store/*.swift ios/Tests/main.swift
"$OUT"
