# Frozen Swift oracle: alert text and dispatch audio

`../../fixtures/swift_alert_text_oracle.tsv` was produced by compiling the
ORIGINAL `EscalationPolicy.swift`, `AlertEntityParser.swift` and
`ScannerIncidents.swift` at commit bea472d (identical at 49492c9, the last
commit before their facade switch) with this harness, and recording its
output together with the Swift runtime rules those files read.
`../../swift_alert_text_oracle.rs` checks the Rust against it: 26,164 records
in 25 kinds, plus the fold and blocker tables over every scalar.

## What it pins

| record | Swift original | Rust twin |
|---|---|---|
| `u-fold`, `u-ci-fold` | `String.folding(options: .caseInsensitive)` per scalar, and whether `localizedCaseInsensitiveContains` itself applies that fold | `swift_text::fold_scalar` (`FOLD_MAP`) |
| `u-ci-after` | the scalars X for which `("ab" + X)` does not contain `"ab"`: blockers of a match's end | `swift_text::blocks_match_end` (`CI_AFTER_BLOCKER_RANGES`) |
| `u-cic` | `localizedCaseInsensitiveContains` for ASCII needles over hays with joiners, marks, ligatures, ß, long s, the Kelvin sign, Hangul jamo and random scalars injected | `swift_text::contains_case_insensitive` |
| `u-split`, `u-int`, `u-locale` | `split(separator: " ")`, `Int(String)`, the locale (en_US) | `split_spaces`, `parse_swift_int` |
| `ae-describes`, `ae-vehicle`, `ae-person`, `ae-colors`, `ae-brands`, `ae-kinds` | `AlertEntityParser` over generated AMBER and weather texts with windows past 60 clusters | `alert_text::describes_an_entity`, `vehicle`, `person` |
| `sc-kind`, `sc-place`, `sc-lifetime`, `sc-order`, `sc-roads`, `sc-consts` | the dispatch parser over generated transcripts with punctuation, signed and non-ASCII numbers, marked spaces | `kind_in_transcript`, `place_phrase`, `phrases`, `lifetime_seconds` |
| `sc-expired`, `sc-visible`, `sc-merged` | the pin rules with NaN coordinates, corridors and expiry edges | `is_expired`, `visible`, `merged_keep` |
| `ep-eval`, `ep-consts` | `EscalationPolicy.evaluate` over 120 simulated drives with NaN and threshold readings and canonically equal ids | `evaluate_escalation` |
| `ep-dismiss` | `EscalationPolicy.dismissed`, the bookkeeping that stays in Swift (read, not compared) | — |

`../places_text/gen_tables.py` writes `FOLD_MAP` and
`CI_AFTER_BLOCKER_RANGES` into `swift_text/tables.rs` from this fixture.

## Reproduce

Bridge-linked: `FlowsCore.swift` and `POIRanking.swift` at the base are
facades that call the bridge. The locale must be en_US.

```sh
BASE=bea472d
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/alert-text-oracle && cd /tmp/alert-text-oracle
FILES="EscalationPolicy AlertEntityParser ScannerIncidents FlowsCore POIRanking TripCosts"
for f in $FILES; do git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"; done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/alert_text/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle body.tsv   # the fixture body (three header lines are prepended)
```

The per-scalar probes take about ten seconds. Three runs, one with
`SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical (sha1 in the fixture's
header line is of the body).
