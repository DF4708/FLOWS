#!/bin/bash
# Build the WMO alerts oracle harness against $BASE's Swift (the original `WMOAlertParsing`, before
# its rules moved to Rust) and its bindings, run it three times (one with deterministic hashing), and print
# the body's sha1 and the record count. Output goes to $OUT, outside the tree.
#
# The harness compiles the test target's own Core sources, as project.yml lists them at $BASE, so it needs no
# stand-ins: the rules run as the app compiles them. The library it links
# (rust/target/xcode/macosx/libflows_bridge.a) must hold every function those bindings name; any build at or
# after $BASE does.
H=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$H/../../../../.." && pwd)}
OUT=${OUT:-${TMPDIR:-/tmp}/wmo-alerts-oracle}
BASE=${BASE:?set BASE to the commit whose Core holds the original rules}
mkdir -p "$OUT" && cd "$OUT" || exit 1
rm -rf src && mkdir src || exit 1
git -C "$REPO" archive "$BASE" apple/FLOWS/Sources/Core apple/FLOWS/RustBridge apple/project.yml | tar -x -C src || exit 1
APP=src/apple
BR="$APP/FLOWS/RustBridge"
# The test target's Core sources: its `- path:` lines under FLOWS/Sources/Core (a folder means every file in it).
awk '/^  FLOWSTests:$/ { on = 1; next } on && /^  [A-Za-z]/ { on = 0 } on && /- path: FLOWS\/Sources\/Core\// { print $3 }' \
  "$APP/project.yml" | while read -r p; do
  if [ -d "$APP/$p" ]; then find "$APP/$p" -name '*.swift' | sort; else echo "$APP/$p"; fi
done > files.txt
[ -s files.txt ] || { echo "no sources listed"; exit 1; }
mkdir -p mod
xcrun --sdk macosx swiftc -O -wmo -emit-module -parse-as-library -swift-version 6 -module-name FlowsBridge \
  -target arm64-apple-macos14.0 -I "$BR" "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  "$BR/flows-bridge/flows-bridge-safe.swift" -emit-module-path mod/FlowsBridge.swiftmodule \
  -emit-object -o mod/FlowsBridge.o > bridge.log 2>&1 || { tail -20 bridge.log; exit 1; }
xcrun --sdk macosx swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 -I "$BR" -I mod \
  $(cat files.txt) "$H/main.swift" mod/FlowsBridge.o \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle > compile.log 2>&1
grep -E "error:" compile.log | head -20
[ -x oracle ] || { echo "no oracle binary"; exit 1; }
echo "harness built ($(grep -c "warning:" compile.log) warnings)"
./oracle run1.tsv && ./oracle run2.tsv && SWIFT_DETERMINISTIC_HASHING=1 ./oracle run3.tsv || { echo "run failed"; exit 1; }
shasum run1.tsv run2.tsv run3.tsv | cut -c1-12
wc -l < run1.tsv
wc -c < run1.tsv
