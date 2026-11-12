#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# The Swift memory-safety gate.
#
# Swift's strict memory safety check (`-strict-memory-safety`) flags every
# expression that touches raw memory: a pointer, an unchecked buffer, a C
# format string. The app targets build with it on (apple/project.yml), and an
# unmarked use is a compile error there. This script is the same check
# without Xcode, in seconds, and it holds two more things the build does not:
#
#   - No flagged place anywhere in the hand-written app code. Raw memory is
#     used only inside apple/FLOWS/Sources/Core/Islands, where each use is
#     marked `unsafe` and states the promise it rests on.
#   - No `unsafe` mark that covers nothing. A mark with nothing under it
#     reads as a promise about code that is not there.
#
# rust/flows-bridge/tests/swift_unsafe_islands.rs is the other half: it fails
# on an `unsafe` mark, a pointer tool or a `String(format:)` outside the
# islands folder. Together: raw memory is marked, and the marks stay in one
# folder.
#
# The generated bridge (apple/FLOWS/RustBridge) is its own module,
# FlowsBridge, and is not checked; no one writes it by hand. The app reaches
# it through the generated safe twins (flows-bridge-safe.swift), which take a
# `Span`, so no app call names a pointer.
#
#   check_swift_memory_safety.sh [check] [macos|ios]
#
# macOS takes seconds; ios takes about five minutes and is the only pass that
# sees code inside `#if os(iOS)`.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/apple/FLOWS"
BR="$APP/RustBridge"
MODE="${1:-check}"
PLAT="${2:-macos}"
case "$MODE" in check) ;; *) echo "usage: $0 [check] [macos|ios]" >&2; exit 2 ;; esac
case "$PLAT" in
  ios) SDK=iphonesimulator; TARGET=arm64-apple-ios17.0-simulator ;;
  macos) SDK=macosx; TARGET=arm64-apple-macos14.0 ;;
  *) echo "usage: $0 [check] [macos|ios]" >&2; exit 2 ;;
esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/flows_sms.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

find "$APP/Sources" -name '*.swift' | sort > "$WORK/files.txt"
if ! xcrun --sdk "$SDK" swiftc -emit-module -parse-as-library -swift-version 6 \
  -module-name FlowsBridge -target "$TARGET" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  "$BR/flows-bridge/flows-bridge-safe.swift" \
  -emit-module-path "$WORK/FlowsBridge.swiftmodule" > "$WORK/bridge.log" 2>&1; then
  grep -E "error:" "$WORK/bridge.log" | head -20 >&2
  echo "swift memory safety: the bridge module did not compile ($PLAT)" >&2
  exit 1
fi
if ! xcrun --sdk "$SDK" swiftc -typecheck -parse-as-library -swift-version 6 \
  -strict-memory-safety -target "$TARGET" -I "$BR" -I "$WORK" \
  $(cat "$WORK/files.txt") > "$WORK/out.log" 2>&1; then
  grep -E "error:" "$WORK/out.log" | head -20 >&2
  echo "swift memory safety: the typecheck itself failed ($PLAT)" >&2
  exit 1
fi

# One line per flagged place (file, line, column). The compiler repeats a
# diagnostic once per file that sees it, so dedupe.
grep -E "\[#(StrictMemorySafety|UnnecessaryEffectMarker::UnnecessaryUnsafe)\]" "$WORK/out.log" \
  | grep -F "$APP/Sources/" \
  | sed "s|^$APP/Sources/||" | LC_ALL=C sort -u > "$WORK/now.txt" || true
TOTAL="$(wc -l < "$WORK/now.txt" | tr -d ' ')"
ISLANDS="$(find "$APP/Sources/Core/Islands" -name '*.swift' | wc -l | tr -d ' ')"
if [ "$TOTAL" = 0 ]; then
  echo "swift memory safety CLEAN ($PLAT): 0 flagged places; raw memory only in the $ISLANDS island files"
  exit 0
fi
echo "swift memory safety FAILED ($PLAT): $TOTAL flagged places" >&2
cut -c1-200 "$WORK/now.txt" | head -40 >&2
echo "Unmarked raw memory: move it behind a helper in Core/Islands. A mark that covers nothing: remove it." >&2
exit 1
