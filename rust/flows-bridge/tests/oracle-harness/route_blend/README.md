# Frozen Swift oracle: the corridor blend

`../../fixtures/swift_route_blend_oracle.tsv` was produced by compiling the
ORIGINAL `RouteBlend.blend` (in `LiveHazardScoring.swift`) at 91798be, the
commit that made the corridor blend one Swift function and the last before
its facade switch, with this harness, and recording its output.
`../../swift_route_blend_oracle.rs` checks the Rust against it.

## What it pins

Every record is one road: its check points, and everything the blend reads
for them. 900 roads, from none to 60 check points. The record holds the
risk of every check point, the worst reading per family, the identified sum
and the unchecked flag, all bit for bit.

- the ZIP field: none, empty, rows shorter or longer than the family list,
  family names repeated, empty or in another case, NaN and infinite scores;
- forecasts at every other check point, at none, at all, with any value
  missing, so a point borrows its neighbour's in the order own, one back,
  one ahead, two back, two ahead;
- ground elevations that put a check point at, above and far above the
  lowest fetched point within four check points, with and without rain;
- river gauges in every flood category (and unknown ones), mapped water
  and closed-road points near, far and absent;
- live feeds of every kind on and off the road, and roads scored with no
  live feeds at all;
- alerts of every scored family, life-safety alerts no family maps
  (they count as a closed road), lookout alerts (they do not), unknown
  events, and severities of 0, 1, NaN and beyond 1.

202 records carry an identified sum, 766 carry at least one family peak,
302 reach a risk of exactly 1, and all eleven peak families appear.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call, so the blend runs with the real field, forecast,
feed and alert code around it. No network, no files, no user data.

## Reproduce

```sh
BASE=91798be bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header. Run against a
later commit, the same script checks the facade: the Swift that now calls
Rust printed the same bytes (sha1 ac0712b1…) on the day of the switch.
