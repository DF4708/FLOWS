#!/bin/bash
# Build the relay-scrape oracle harness against $BASE's Swift and bindings (the commit that made
# TruckerRadio.relayChannels a pure static), run it three times (one with deterministic hashing),
# and print the body's sha1 and the record count. Output goes to $OUT, outside the tree.
H=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$H/../../../../.." && pwd)}
OUT=${OUT:-${TMPDIR:-/tmp}/relay-oracle}
BASE=${BASE:?set BASE to the commit that made relayChannels a pure static}
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p "$OUT" && cd "$OUT" || exit 1
FILES="TruckerRadio RadioTuning POIRanking"
for f in $FILES; do git -C "$REPO" show "${BASE}:apple/FLOWS/Sources/Core/${f}.swift" > "${f}.swift" || exit 1; done
git -C "$REPO" show "${BASE}:apple/FLOWS/RustBridge/flows-bridge/flows-bridge.swift" > bindings.swift || exit 1
python3 - "$REPO" "$BASE" > stubs.swift <<'PY' || exit 1
import subprocess, sys
repo, base = sys.argv[1], sys.argv[2]
def show(path):
    return subprocess.run(['git', '-C', repo, 'show', f'{base}:{path}'], capture_output=True, text=True, check=True).stdout
brand = show('apple/FLOWS/Sources/Core/BrandKnowledge.swift')
b = brand.index('extension RustStringRef')
ext = brand[b:brand.index('\n}\n', b) + 3]
costs = show('apple/FLOWS/Sources/Core/TripCosts.swift')
c = costs.index('extension FuelType {')
fuel = costs[c:costs.index('\n}\n', c) + 3]
print(f'''import CoreLocation
import Foundation
// Names TruckerRadio.swift mentions that the oracle never exercises. TruckerRadio is never instantiated: its init reads
// the user's Application Support and UserDefaults. ThrottledNet never reaches the network.
enum ThrottledNet {{
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) {{ throw URLError(.notConnectedToInternet) }}
}}
enum FlowsDiag {{
    enum Level {{ case info, warn, fail }}
    nonisolated static func log(_ level: Level = .info, _ area: String, _ message: String) {{}}
    nonisolated static func logThrottled(key: String, interval: TimeInterval, _ level: Level = .info,
                                         _ area: String, _ message: String) {{}}
}}
/// The bridge text helper TruckerRadio and POIRanking read (a verbatim copy of BrandKnowledge.swift's at {base}).
{ext}
/// The fuel code POIRanking sends (a verbatim copy of TripCosts.swift's at {base}).
{fuel}''')
PY
cp "$H/main.swift" .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" bindings.swift \
  $(for f in $FILES; do printf "%s.swift " "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle > compile.log 2>&1
grep -E "error:" compile.log | head -20
[ -x oracle ] || { echo "no oracle binary"; exit 1; }
echo "harness built ($(grep -c "warning:" compile.log) warnings)"
./oracle run1.tsv && ./oracle run2.tsv && SWIFT_DETERMINISTIC_HASHING=1 ./oracle run3.tsv || { echo "run failed"; exit 1; }
shasum run1.tsv run2.tsv run3.tsv | cut -c1-12
wc -l < run1.tsv
cut -f1 run1.tsv | sort | uniq -c
awk -F'\t' '$4 != "-"' run1.tsv | wc -l | sed 's/^/pages that parsed: /'
