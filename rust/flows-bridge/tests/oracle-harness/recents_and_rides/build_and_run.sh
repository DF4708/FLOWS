#!/bin/bash
# Build the fourth-landing oracle harness against c206b98's Swift and bindings, run it three times (one with
# deterministic hashing), and print the body's sha1 and the record count per kind. Output goes to $OUT.
# The stubs are generated here from c206b98 so every copied table and helper is byte-exact.
H=$(cd "$(dirname "$0")" && pwd)
# The repository root, five levels up; the build lands outside the tree.
REPO=${REPO:-$(cd "$H/../../../../.." && pwd)}
OUT=${OUT:-${TMPDIR:-/tmp}/recents-oracle}
BASE=c206b98
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p "$OUT" && cd "$OUT" || exit 1
FILES="DestinationSearch DestinationPrediction POIRanking TransitItinerary HybridWalk TruckerRadio RadioTuning"
for f in $FILES; do git -C "$REPO" show "${BASE}:apple/FLOWS/Sources/Core/${f}.swift" > "${f}.swift" || exit 1; done
git -C "$REPO" show "${BASE}:apple/FLOWS/RustBridge/flows-bridge/flows-bridge.swift" > bindings.swift || exit 1
# A verbatim span of a file at $BASE: from the first line that starts with $2 through the first line after it
# that is exactly $3.
span() {
  git -C "$REPO" cat-file -e "${BASE}:$1" || exit 1
  git -C "$REPO" show "${BASE}:$1" | awk -v start="$2" -v end="$3" '
    !on && index($0, start) == 1 { on = 1 }
    on { print }
    on && $0 == end { exit }'
}
{
cat <<'SWIFT'
import CoreLocation
import Foundation
// Names the files under test mention that the oracle never exercises. SecureBehaviorStore is a stub on purpose: the
// real one reads and writes the user's Application Support files. ThrottledNet never reaches the network.
enum SecureBehaviorStore {
    static func readMigrating(_ url: URL) -> Data? { nil }
    @discardableResult static func save<T: Encodable>(_ value: T, to url: URL) -> Bool { true }
    static func shred(_ url: URL) {}
}
enum ThrottledNet {
    static func fetch(_ url: URL) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
}
enum FlowsDiag {
    enum Level { case info, warn, fail }
    nonisolated static func log(_ level: Level = .info, _ area: String, _ message: String) {}
    nonisolated static func logThrottled(key: String, interval: TimeInterval, _ level: Level = .info,
                                         _ area: String, _ message: String) {}
}
SWIFT
echo "/// The state boxes TruckerRadio.position reads: a byte-for-byte copy of LiveHazardFeeds.swift's table at $BASE."
echo "enum LiveHazardFeedFetcher {"
span apple/FLOWS/Sources/Core/LiveHazardFeeds.swift '    static let stateBBoxes' '    ]'
echo "}"
echo "/// The bridge text helper POIRanking reads (a verbatim copy of BrandKnowledge.swift's at $BASE)."
span apple/FLOWS/Sources/Core/BrandKnowledge.swift 'extension RustStringRef' '}'
echo
echo "/// The fuel code POIRanking sends (a verbatim copy of TripCosts.swift's at $BASE)."
span apple/FLOWS/Sources/Core/TripCosts.swift 'extension FuelType {' '}'
echo
} > stubs.swift
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
