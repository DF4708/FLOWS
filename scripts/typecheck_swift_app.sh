#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# Typechecks every app Swift source together with the generated Rust bridge,
# for macOS, without Xcode. Use it to verify a Swift facade against the
# bindings in seconds; the real gate is still the FLOWSTests suite and the
# Release matrix. Run `cargo build -p flows-bridge` first so the generated
# bindings are current.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/apple/FLOWS"
BR="$APP/RustBridge"
find "$APP/Sources" -name '*.swift' | sort > "${TMPDIR:-/tmp}/flows_typecheck_files.txt"
xcrun --sdk macosx swiftc -typecheck -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(cat "${TMPDIR:-/tmp}/flows_typecheck_files.txt")
echo "typecheck OK: $(wc -l < "${TMPDIR:-/tmp}/flows_typecheck_files.txt" | tr -d ' ') app files + bridge"
