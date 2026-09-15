# Frozen Swift oracle: climate and astronomy

`../../fixtures/swift_climate_oracle.tsv` was produced by compiling the
ORIGINAL Swift (`ClimateProfiles`, `LatitudeBands`, `DaylightClock`,
`HarmonicClimatology`, `RiskTiming`) with this harness and recording its
output, before that math moved to `flows_core::climate`.
`../../swift_climate_oracle.rs` checks the Rust against it: 13,447 records in
37 kinds.

## Three record shapes

- **explicit** — one input and its output per line;
- **`set` / `dg`** — named input lists, then an FNV-1a-64 digest over their
  product, hashed in the order written beside each loop; the Rust test
  rebuilds the digest from the same lists;
- **`rnd`** — a digest over a SplitMix64 sweep the Rust test regenerates draw
  for draw (the draw order is written beside each sweep).

Digests are bit-exact by construction, so they cover only values with no
trigonometry in them, or trigonometry that the fixture shows to match bit
for bit (the 52 weekly angles of the harmonic table; the 212,550-value day
digest). The three sweeps over the daylight functions (`rday`, `rdha`,
`rdmj`) are written out sample by sample instead: the Release compiler fuses
sin/cos pairs, whose sine can differ from a standalone sin by one ulp, and a
digest would break on a difference that means nothing physically. The test
compares those, and every explicit trig record, to a stated tolerance
(declination and equation of time within 1e-9, hour angles within a
nanominute, instants within a microsecond, the sun's height within a
nanodegree); at this writing five values in 13,447 needed it, the largest by
6e-14, and every instant matched bit for bit.

## What it pins

| record | Swift original (base commit) | Rust twin |
|---|---|---|
| `const` | the statics of all five files | the `climate` constants |
| `lbi`, `lbs`, `lbp` | `LatitudeBands.bandIndex`, `.elevationBandShift`, `.profile` | `band_index`, `elevation_band_shift`, `band_profile` |
| `ctype`, `ccl`, `cpr`, `csn`, `ctb`, `cwb` | `ClimateType` profiles, `classify`, `profile`, `seasonalNorms`, `temperatureBeyondNormal`, `windBeyondNormal` | `ClimateType::profile`, `classify`, `climate_profile`, `seasonal_norms`, `temperature_beyond_normal`, `wind_beyond_normal` |
| `dref`, `dcmp` | Foundation `Date` arithmetic and comparisons the port relies on | `unix_seconds`, `reference_seconds`; `<`, `>`, `==`, and Comparable's `<=`/`>=` |
| `djd`, `dmj`, `dst`, `dha`, `dday`, `dtw`, `dnone` | `DaylightClock.julianDay`, `.midnightJD`, `.solarTerms`, `.hourAngleMinutes`, `.twilight`, `.isNight`, `.solarElevation`, `.nextChange` | the same names |
| `hwt`, `hp`, `hzc`, `hzi`, `hzm`, `hsn`, `hsc`, `hst`, `hbig` | `HarmonicClimatology.WeekTrig`, `init?(data:)`, `zipIndexMap`, `zipIndex`, `score(zip:family:week:)`, `score(zipIndex:familyIndex:week:)`, `score(…trig:)`; the 33,613-ZIP table | `WeekTrig`, `parse_flhh`, `HarmonicTable::{zip_index_map, zip_index, score_named, score_week, score}` |
| `rta`, `rto` | `RiskTiming.isActive`, `.arrivalOffsets` | `is_active`, `arrival_offsets` |
| `trap` | inputs that trap the Swift, each observed in a child process | the `None` returns |

## Two things the fixture taught

- Foundation's `String(bytes:encoding: .utf8)` drops one leading byte-order
  mark; the Rust decoder does the same (`hp` table 8 pins it). Its `String`
  `==` and `<` treat canonically equivalent spellings as equal; the port
  compares bytes, because the FLHH writer emits ASCII digits and ASCII family
  names. On the two odd-UTF-8 tables the test counts the records where those
  differ — exactly 287 — and requires every one to involve a non-ASCII key
  or query.
- `RiskTiming.arrivalOffsets(sampleCount: Int.max)` does not trap: Swift
  starts allocating and the process grows until the machine runs out of
  memory. The first version of this harness probed it and held the machine;
  the probe is gone and the finding stays as a comment. The port refuses
  counts above 2^20 with `None`.

## Reproduce

The base commit is named in the fixture's first line.

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
mkdir -p /tmp/climate-oracle && cd /tmp/climate-oracle
for f in ClimateProfiles LatitudeBands DaylightClock HarmonicClimatology RiskTiming; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/climate/main.swift" .
xcrun --sdk macosx swiftc -O -swift-version 5 ClimateProfiles.swift LatitudeBands.swift DaylightClock.swift HarmonicClimatology.swift RiskTiming.swift main.swift -o oracle
./oracle   # the fixture body (the harness prints its own two header lines; a third is prepended)
```

The binary imports `__sincos_stret`, `sin`, `cos`, `tan`, `asin`, `acos` and
`fmod`. Four runs are byte-identical: three plain runs and one with
`SWIFT_DETERMINISTIC_HASHING=1` (sha1
`5d153bd28a80b87e34d715183f74c9ee419daf78` for the body).
