# Facade parity: the geo facade

The geo kernel's oracle is `../../fixtures/swift_geo_oracle.tsv`, frozen at
a007de0 from the original Swift and checked against `flows_core::geo` by
`../../swift_geo_oracle.rs` (see `../geo/README.md`). This harness checks
the other half: that the app's facades hand the right numbers to Rust and
back. It feeds the inputs of the oracle's `m`, `brg` and `ahead` records to

- `POIRanking.meters` (`flows_geo_meters`),
- `EnforcementCameras.bearingDegrees` and `FuelWarning.bearingDegrees`
  (`flows_geo_bearing_degrees`),
- `EnforcementCameras.isAhead` (`flows_geo_camera_is_ahead`),

compiled with the test target's own Core sources and linked against the
bridge, and writes each record again with the facades' answers.

## What it allows

The same as the Rust oracle, by the same measures, and nothing else:

- `meters` matches every record, bit for bit;
- a bearing may differ where the original Swift's Release build fused its
  sine and cosine, moving its target by at most a micrometre on the ground
  (error in radians times the separation);
- an ahead answer may flip only where the bearing lies within a nanodegree
  of the cone's edge.

Anything else counts as outside, and the run fails.

At the facade switch (2026-11-12): 985 `m` records with none different;
720 `brg` records with 9 different, the largest by 1.65e-7 m, the same 9
and the same gap the Rust oracle reports; 722 `ahead` records with 13
flipped, the largest 4e-11 degrees from the edge. Three runs are
byte-identical (sha1 `b6b98d19d58e`, 2,427 records).

## Wrong forwarders it catches

Each of these facades was built and run once, then put back:

- `meters` with the second point's latitude and longitude swapped: 862
  records outside;
- `isAhead` always passing a heading, so no heading reads as due north: 2;
- `bearingDegrees` from the second point to the first: 700.

## Reproduce

```sh
git add -A; T=$(git write-tree); git reset -q
OUT=<a folder outside the tree> BASE=$T bash rust/flows-bridge/tests/oracle-harness/geo_facade/build_and_run.sh
```

`BASE` is any commit (or tree) whose Core holds the facades; the library it
links (`rust/target/xcode/macosx/libflows_bridge.a`) must be built from it.
