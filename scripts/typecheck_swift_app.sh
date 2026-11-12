#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# Typechecks every app Swift source together with the generated Rust bridge,
# without Xcode. Use it to verify a Swift facade against the bindings in
# seconds; the real gate is still the FLOWSTests suite and the Release matrix.
# Strict memory safety is on, as in the app targets: an unmarked use of raw
# memory is an error.
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
# The generated bridge is its own module (FlowsBridge), as in the Xcode
# build: compile its interface first, then check the app against it.
MOD="${TMPDIR:-/tmp}/flows_bridge_module_$SDK"
mkdir -p "$MOD"
xcrun --sdk "$SDK" swiftc -emit-module -parse-as-library -swift-version 6 \
  -module-name FlowsBridge -target "$TARGET" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  "$BR/flows-bridge/flows-bridge-safe.swift" \
  -emit-module-path "$MOD/FlowsBridge.swiftmodule"
xcrun --sdk "$SDK" swiftc -typecheck -parse-as-library -swift-version 6 \
  -strict-memory-safety -Werror StrictMemorySafety -target "$TARGET" -I "$BR" -I "$MOD" \
  $(cat "${TMPDIR:-/tmp}/flows_typecheck_files.txt")
echo "typecheck OK ($SDK): $(wc -l < "${TMPDIR:-/tmp}/flows_typecheck_files.txt" | tr -d ' ') app files + bridge"
