#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# Typechecks every app Swift source together with the generated Rust bridge,
# without Xcode. Use it to verify a Swift facade against the bindings in
# seconds; the real gate is still the FLOWSTests suite and the Release matrix.
# Run `cargo build -p flows-bridge` first so the generated bindings are current.
#
#   typecheck_swift_app.sh        macOS (the default; seconds)
#   typecheck_swift_app.sh ios    iPhone simulator SDK (about five minutes) —
#                                 the only way, short of an Xcode build, to
#                                 check code inside `#if os(iOS)`, which the
#                                 macOS pass never compiles.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/apple/FLOWS"
BR="$APP/RustBridge"
case "${1:-macos}" in
  ios) SDK=iphonesimulator; TARGET=arm64-apple-ios17.0-simulator ;;
  macos) SDK=macosx; TARGET=arm64-apple-macos14.0 ;;
  *) echo "usage: $0 [macos|ios]" >&2; exit 2 ;;
esac
find "$APP/Sources" -name '*.swift' | sort > "${TMPDIR:-/tmp}/flows_typecheck_files.txt"
xcrun --sdk "$SDK" swiftc -typecheck -parse-as-library -swift-version 5 \
  -target "$TARGET" \
  -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(cat "${TMPDIR:-/tmp}/flows_typecheck_files.txt")
echo "typecheck OK ($SDK): $(wc -l < "${TMPDIR:-/tmp}/flows_typecheck_files.txt" | tr -d ' ') app files + bridge"
