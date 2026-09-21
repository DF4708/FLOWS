# Frozen Swift oracle: brand, price and tag text

`../../fixtures/swift_places_text_oracle.tsv` was produced by compiling the
ORIGINAL Swift (`BrandKnowledge`, `RatingsAndCost`, `FuelPrices`, `LaneData`,
`EnforcementCameras`) with this harness and recording its output, before that
code moved to `flows_core::places_text`. `../../swift_places_text_oracle.rs`
checks the Rust against it: 23,594 records in 35 kinds.

## Two halves

These files stand on Swift's `String`: grapheme clusters, `Character.isLetter`
and `isNumber`, `lowercased()`/`uppercased()`, canonical equivalence in `==`
and in dictionary keys, Foundation's `range(of:)`/`components`/
`replacingOccurrences`, `hasSuffix`, `trimmingCharacters`, and
`Double(String)`. So the harness first reads the Swift runtime's own tables,
scalar by scalar over the whole domain, and the Rust embeds them
(`flows_core::swift_text::tables`, written by `../../swift_text_tables.rs` from these
records):

| record | what it reads |
|---|---|
| `u-word`, `u-num`, `u-ws` | `Character.isLetter || isNumber`, `isNumber`, `CharacterSet.whitespaces`, as inclusive scalar ranges |
| `u-gcb` | for every scalar, a 17-bit vector: is probe *i*, with the scalar spliced in, one `Character`? The probes tell every grapheme-break class apart (Control, CR, LF, Extend with and without Indic_Conjunct_Break, SpacingMark, Prepend, Extended_Pictographic, Consonant, Linker, ZWJ, Regional_Indicator, L, V, T, LV, LVT) |
| `u-seg` | 2,500 random scalar sequences over every class and the size of each `Character` in them, forward and backward agreeing |
| `u-lower`, `u-upper` | `Unicode.Scalar.Properties.lowercaseMapping`/`uppercaseMapping` where they are not the scalar |
| `u-nfd`, `u-ccc`, `u-canon` | `decomposedStringWithCanonicalMapping` outside the Hangul syllables, `canonicalCombiningClass` as ranges, and the non-ASCII scalars canonically equal to ASCII |

The oracle test compares the embedded tables to these records over all
1,112,064 scalars and the segmenter to every `u-seg` sequence. The second
half pins the ported functions themselves:

| record | Swift original (base commit) | Rust twin |
|---|---|---|
| `bk`, `bk-shelter`, `bk-asked` | `BrandKnowledge.costTier`, `.website`, `.gymHasShowers`, `.parkingFee`, `.isShelterNoise`; `.shelterType`; `.askedName` | `cost_tier`, `website`, `gym_has_showers`, `parking_fee`, `is_shelter_noise`, `shelter_type`, `asked_name_matches` |
| `rc-country`, `rc-bp`, `rc-tier`, `rc-tier-usd`, `rc-nightly`, `rc-yelp` | `Country.forCoordinate`, `.checkBreakpoints`, `costTier(averageCheck:country:)`, `costTier(averageCheckUSD:)`, `estimatedNightly`, `costTier(yelpPrice:rating:)` | `country_for_coordinate`, `check_breakpoints`, `cost_tier_for_check`, `estimated_nightly`, `yelp_cost_tier` |
| `sh-name`, `sh-ladder`, `sh-table` + `sh-entry`, `sh-city` | `ShowerAvailability.forStop(named:)`, `.forStop(named:lat:lon:table:)` with the driver's report and the table read, `LocationTable.entry(nearLat:lon:)`, `CityTable.showers(state:city:)` | `shower_for_name`, `shower_ladder`, `shower_table_entry`, `city_keys` (+ the dictionary, recomposed) |
| `fp-const`, `fp-factor`, `fp-name`, `fp-mxn`, `fp-mex`, `fp-live`, `fp-est`, `fp-aaa` | the statics and tables, `usdPerGallon`, `mexicoEstimate`, `AAAFuelPrices.refresh` through a stub transport, `estimate`, `parseCurrentAvg` | the constants, `STATE_FACTORS`, `STATE_NAMES`, `usd_per_gallon`, `mexico_estimate`, `parse_current_avg` (+ the cache, recomposed), `fuel_state_code` + `fuel_estimate` |
| `ld-parse` | `LaneData.parse(turnLanes:)` | `parse_turn_lanes` |
| `ec-kind`, `ec-limit` | `EnforcementCameras.kind(fromTags:)`, `.limitMph(fromTags:)` | `camera_kind`, `camera_limit_mph` |

Inputs are adversarial on purpose: combining marks after letters and after
`$`, joiners, prepends, flags, Indic conjuncts, fullwidth and Kelvin letters,
NULs, every kind of whitespace, hex floats and NaN payloads in `maxspeed`,
and the AAA row's 600-character window probed with multi-scalar clusters so
a byte or scalar count would land on the wrong side.

## What the fixture taught

- `Character.isLetter`/`isNumber` read the cluster's first scalar; a Roman
  numeral is both.
- `lowercased()` is the full mapping with no context: a final sigma stays σ.
- Foundation's non-literal search matches whole clusters canonically:
  `"$\u{301}5".contains("$")` is false, `"\u{212A}S" == "KS"` is true, and
  `trimmingCharacters` works on scalars, not clusters.
- `Double(String)` is Darwin's `strtod` behind Swift's own checks: it refuses
  a leading space and an empty string, ends at the first NUL, takes `0x` (not
  `0X`) hex floats correctly rounded, and reads `nan(…)`/`snan(…)` payloads
  as `0x` hex, `0` octal or decimal, wrapping in 64 bits and kept to 50 bits
  under the quiet (bit 51) or signaling (bit 50) marker. Overflow is infinity
  and underflow zero, not `nil`.
- `ClimateProfiles`-style private helpers were not the problem here; the
  hard part was the runtime, and the answer was to read the runtime out.

## Reproduce

The base commit is named in the fixture's header. `stubs.swift` stands in
for `ThrottledNet` (answering AAA pages from `aaaPages`), `CacheEviction`,
`FuelType`, `POIRanking` and `ManeuverSymbol.Side`, none of which the oracle
exercises beyond that. (The loop is `sh`/`bash` syntax.)

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
mkdir -p /tmp/places-oracle && cd /tmp/places-oracle
for f in BrandKnowledge RatingsAndCost FuelPrices LaneData EnforcementCameras; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/places_text/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 BrandKnowledge.swift RatingsAndCost.swift FuelPrices.swift \
  LaneData.swift EnforcementCameras.swift stubs.swift main.swift -o oracle
./oracle   # the fixture body (the harness prints its own "# base" line; three header lines are prepended)
FLOWS_WRITE_SWIFT_TEXT_TABLES=1 cargo test --manifest-path "$REPO/rust/Cargo.toml" -p flows-bridge --test swift_text_tables   # rewrites swift_text/tables.rs
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 `e6b1bd9e0a1c1d8265ac698bc6bfc44da74e22be` for the body). The runtime
was Swift 6.4 (Xcode 27); a newer runtime with newer Unicode tables would
change the `u-*` records, and the generator and the test are built so that
such a change is visible, not silent.
