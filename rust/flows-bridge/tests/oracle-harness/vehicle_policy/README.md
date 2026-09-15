# Frozen Swift oracle: vehicle policy

`../../fixtures/swift_vehicle_policy_oracle.tsv` was produced by compiling the
ORIGINAL Swift implementation, before it was replaced by calls into Rust, with
this harness, and recording its output. `../../swift_vehicle_policy_oracle.rs`
compares Rust against it bit for bit.

The functions covered: `SpeedLaw` (estimated, effective, state and federal
limits, standing), the `CompassReading.points` table, `SpeedSign`
(`parseMaxspeed`, `judge`), `PursuitReach.radiusMeters`, `TowingLimits`
(`estimatedRatings`, `Ratings.effectiveGCWR`, `check`), `FilterLimits` (the
three admission rules, `degreesToPercent`, `vehicleDefaultMaxGradeDegrees`),
`GradeProfile` (`segments`, `steepest`, `nextSteep`) and `DriveEfficiency`
(every penalty, headwind, airspeed, drag sensitivity, load factor, score,
verdict, efficient cruise), plus every policy constant.

Reproduce (the base commit is named in the fixture's first line):

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
mkdir -p /tmp/oracle && cd /tmp/oracle
for f in SpeedLaw SpeedSign TowingLimits POIRanking FilterLimits GradeProfile PursuitReach DriveEfficiency; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/vehicle_policy/main.swift" .
xcrun --sdk macosx swiftc -O -swift-version 5 SpeedLaw.swift SpeedSign.swift TowingLimits.swift \
  POIRanking.swift FilterLimits.swift GradeProfile.swift PursuitReach.swift DriveEfficiency.swift \
  main.swift -o oracle
./oracle   # the fixture body, byte for byte (header lines are prepended)
```

`POIRanking.swift` is compiled only because it declares `FuelType`, which
`TowingLimits.estimatedRatings` takes; nothing else in it is exercised.

Rules the harness follows, so the output is a function of the code alone:
- a seeded SplitMix64, never a system random source;
- never iterate a `Dictionary` or `Set` to choose inputs or order outputs;
- doubles as IEEE bit patterns in hex, strings as UTF-8 hex;
- three runs plus one with `SWIFT_DETERMINISTIC_HASHING=1` were byte-identical
  (14,260 records in 35 kinds; sha1 `010d90f44cb3c134b07d4cfd2e9a4a6ba03b9e42`
  for the body).

The `utab` records are the Unicode properties `SpeedSign.parseMaxspeed`
consults through Swift's `String` (`Character.isNumber`, grapheme-cluster
joins before and after an ASCII character, `CharacterSet.whitespaces`), read
from the Swift runtime over every scalar and written as inclusive ranges. The
Rust port embeds the same ranges and the test checks them over the whole
scalar domain; the `pm` records then check the parse itself, including a
string at every range edge.

Two `pr` records carry a NaN in both arguments. IEEE 754 leaves which
operand's NaN a product returns to the hardware (Apple silicon: the first
operand's), and the Swift Release build emitted `PursuitReach.radiusMeters`'s
product with the speed first; the Rust writes it in that order and says why.
