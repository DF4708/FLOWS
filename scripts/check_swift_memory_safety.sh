#!/bin/sh
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
#
# The Swift memory-safety gate.
#
# Swift's strict memory safety check (`-strict-memory-safety`) flags every
# expression that touches raw memory: a pointer, an unchecked buffer, a C
# format string. FLOWS cannot run with zero of them, because every call into
# the Rust core hands Rust a buffer through the generated bridge, and the
# bridge's own types are raw pointers. So this gate holds the line instead:
# the number of flagged places in each hand-written file is written down in
# scripts/swift_memory_safety_<platform>.tsv, and the check fails when any
# file's number differs from the list.
#
#   - A number that went UP, or a new file, is new raw-memory code. Move it
#     behind a helper in apple/FLOWS/Sources/Core/Islands, or, when it is
#     only one more bridge call through the facade, run `update` and say so
#     in the commit.
#   - A number that went DOWN is good news that must be written down, so the
#     list never has slack to hide new code in: run `update`.
#
# The generated bridge (apple/FLOWS/RustBridge) is its own module,
# FlowsBridge, and is not counted; no one writes it by hand.
#
# What this does not see: Apple's check (Swift 6.4.2) says nothing about
# `$0.baseAddress!.pointee` written straight inside a `withUnsafe...`
# closure. rust/flows-bridge/tests/swift_unsafe_islands.rs covers that side:
# it fails on any `withUnsafe...` outside Core/Islands. The two gates go
# together.
#
#   check_swift_memory_safety.sh [check|update] [macos|ios]
#
# macOS takes seconds; ios takes about five minutes and is the only pass that
# sees code inside `#if os(iOS)`.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/apple/FLOWS"
BR="$APP/RustBridge"
MODE="${1:-check}"
PLAT="${2:-macos}"
case "$MODE" in check | update) ;; *) echo "usage: $0 [check|update] [macos|ios]" >&2; exit 2 ;; esac
case "$PLAT" in
  ios) SDK=iphonesimulator; TARGET=arm64-apple-ios17.0-simulator ;;
  macos) SDK=macosx; TARGET=arm64-apple-macos14.0 ;;
  *) echo "usage: $0 [check|update] [macos|ios]" >&2; exit 2 ;;
esac
LIST="$REPO/scripts/swift_memory_safety_$PLAT.tsv"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/flows_sms.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

find "$APP/Sources" -name '*.swift' | sort > "$WORK/files.txt"
if ! xcrun --sdk "$SDK" swiftc -emit-module -parse-as-library -swift-version 6 \
  -module-name FlowsBridge -target "$TARGET" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
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

# One line per flagged place (file, line, column), counted per file. The
# compiler repeats a diagnostic once per file that sees it, so dedupe first.
grep -F "[#StrictMemorySafety]" "$WORK/out.log" \
  | grep -F "$APP/Sources/" \
  | sed "s|^$APP/Sources/||" \
  | awk -F: '{ print $1 ":" $2 ":" $3 }' | sort -u \
  | awk -F: '{ n[$1]++ } END { for (f in n) printf "%s\t%d\n", f, n[f] }' \
  | LC_ALL=C sort > "$WORK/now.tsv"
TOTAL="$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$WORK/now.tsv")"
FILES="$(wc -l < "$WORK/now.tsv" | tr -d ' ')"

if [ "$MODE" = update ]; then
  {
    echo "# Places Swift's strict memory safety check flags, per hand-written file ($PLAT)."
    echo "# Made by scripts/check_swift_memory_safety.sh update $PLAT; do not edit by hand."
    echo "# Compiler: $(xcrun --sdk "$SDK" swiftc --version 2>&1 | sed -n 's/.*\(Apple Swift version [0-9.]*\).*/\1/p' | head -1)"
    cat "$WORK/now.tsv"
  } > "$LIST"
  echo "swift memory safety list written ($PLAT): $TOTAL places in $FILES files"
  exit 0
fi

[ -f "$LIST" ] || { echo "swift memory safety: no list at $LIST; run update" >&2; exit 1; }
grep -v '^#' "$LIST" > "$WORK/want.tsv"
if cmp -s "$WORK/want.tsv" "$WORK/now.tsv"; then
  echo "swift memory safety HELD ($PLAT): $TOTAL places in $FILES files, same as the list"
  exit 0
fi
echo "swift memory safety MOVED ($PLAT). file: listed -> now" >&2
awk -F'\t' 'NR == FNR { want[$1] = $2; next } { now[$1] = $2 }
  END {
    for (f in now) if (!(f in want)) printf "  NEW   %s: 0 -> %d\n", f, now[f]
      else if (now[f] > want[f]) printf "  UP    %s: %d -> %d\n", f, want[f], now[f]
      else if (now[f] < want[f]) printf "  DOWN  %s: %d -> %d\n", f, want[f], now[f]
    for (f in want) if (!(f in now)) printf "  DOWN  %s: %d -> 0\n", f, want[f]
  }' "$WORK/want.tsv" "$WORK/now.tsv" | LC_ALL=C sort >&2
echo "list compiler: $(sed -n 's/^# Compiler: //p' "$LIST"); this compiler: $(xcrun --sdk "$SDK" swiftc --version 2>&1 | sed -n 's/.*\(Apple Swift version [0-9.]*\).*/\1/p' | head -1)" >&2
echo "UP or NEW: move the raw-memory code into Core/Islands, or run 'update' and explain it. DOWN: run 'update'." >&2
exit 1
