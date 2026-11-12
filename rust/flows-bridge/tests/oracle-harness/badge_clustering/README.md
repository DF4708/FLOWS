# Frozen Swift oracle: the map's hazard badges

`../../fixtures/swift_badge_clustering_oracle.tsv` was produced by
compiling the ORIGINAL `BadgeClustering` (`BadgeClustering.swift`) at
6343007, the last commit before the facade switch, with this harness, and
recording its output. `../../swift_badge_clustering_oracle.rs` checks the
Rust against it.

## What it pins

2,972 records.

- `k` (587) and `d` (587): `cluster` and `declutter` on the same sets.
  Thirteen hand-made sets (none, one item, the same item twice, two kinds
  overlapping, an 80-point corridor, 70 points near each pole, 66 copies
  of one point, NaN scores in a set of 64 and one of 63, a column of
  latitudes from -75 to 73.5, latitudes past 90, and 81 points exactly on
  the cell edges of a 5 km grid) each run with every separation in
  0, -1, NaN, infinity, 1 m, 500 m, 5 km, 50 km, 500 km, the smallest
  double and 1e300. Then 170 random sets of 1 to 130 items (63, 64 and 65
  among them, either side of the grid), one to four kinds, some with
  special values, each with three separations;
- `b` (500): `labels`, random badges and labelled points with ties in the
  scores, a labelled point exactly on a badge, and two at the same
  distance from one;
- `w` (108): `isWarning` on alert events in every case, with combining
  marks, the Kelvin sign, dotted and dotless I, fullwidth letters, emoji,
  CRLF, ligatures and Café in NFC and NFD;
- `s` (490): `sameHazard` for 49 badge events (nil among them) against 10
  shown events;
- `u` (700): `unshown`, with no rings, two-point rings, rings with special
  values, a ring whose box edge passes exactly through a badge, merge
  distances including 0, -1, NaN and infinity, and both the default
  `sameHazard` and one that answers by the scores' bits.

The `u` closures are rules of the items' own bits, which the Rust test
repeats: `minor` is a score whose bit pattern is odd, and the second
`sameHazard` answers yes when bit 1 of the two scores' XOR is clear.

66 cluster calls are left out: the original's grid path (64 or more items
and a positive spacing) traps converting a NaN, infinite or too-large
cell to `Int`, so it cannot be asked. The harness skips them by the
original's own arithmetic (`gridTraps`). The Rust takes the linear scan
there instead (see `flows_core::badges`); the grid only speeds it up.

## What it found

The answers are the original's bits because the Rust copies Swift's own
helpers: the sort is Swift's (an insertion sort below 64 elements, which
places a NaN score where Swift does), `max(score, 1e-4)` keeps a NaN
score, the bounds fold from the infinities with Swift's `min` and `max`,
and the text rules read events through `swift_text` (Swift's
`lowercased()`, Foundation's `contains` and Swift's `==`, which is
canonical equivalence).

Thirty-seven changed rules were tried against the fixture before the
facade switch. Twenty-eight failed it: the sort by `>=` (192 records), a
weight floor of 1e-3 (269), the weight by Rust's `max` (84), the badge
keeping its last member (305), the linear scan by `<=` (2), across kinds
(115) or taking the last match (62), the grid's cosine floored at 0.5 (19),
its cells not widened by the cosine (50), never skipping a later seed (85)
or looking at only two rows (102), declutter's ties in reverse (179) or by
`<=` (3), labels by `<=` on the radius (16), across kinds (96) or a later
worst on a tie (58), `isWarning` without "emergency" (54) or without
`lowercased()` (275), `sameHazard` without its warning test (217) or by
bytes (2), the box's lower edge by `>` (21), `unshown` by `<=` (20),
across kinds (52), without `sameHazard` (42), a minor badge kept beside a
near one (36), no areas (136), the box alone (45) and the even–odd test
alone (1).

Three more survived the fixture, and three tests in the same file kill
them: the grid by `<=` (the oracle cannot put a point exactly the spacing
from a seed on the grid's path; `an_item_exactly_the_spacing_away_seeds_its_own_badge`),
the nearest badge by `<=` on a tie (`a_tie_for_the_nearest_badge_goes_to_the_first`),
and `near_same_kind` by `<=` (the fixture asks `unshown`, which never
reads it; `near_same_kind_names_exactly_the_pairs_unshown_asks_about`).

Six more survived, and each is the same rule written another way:

- the grid threshold at 63 or 65, and no grid at all (three of the six):
  the grid gives the linear scan's answer, which is why the original
  could switch at any size;
- a zero spacing sent to the grid: nothing is closer than zero, and the
  cells it would build are not numbers, so it falls to the linear scan;
- the grid skipping a seed only when it is later instead of later or the
  same: each seed sits in one cell once, so the same seed never comes
  twice;
- the bounds by Rust's `min`: starting from infinity, Swift's `min` and
  Rust's agree on everything but which signed zero comes back, and the
  box test reads both zeros alike.

After the switch, nine changed facades were run through this harness
against the switched Swift's own output. Eight failed it: the rings sent
as longitudes only (135 records), the labelled points numbered apart
from the badges (83), each point given the next badge's label (209),
`sameHazard`'s events swapped (244), the centroid's latitude and
longitude swapped (550), the items sent with longitude for latitude
(1,191), the wrong item of each near pair asked about (173) and `minor`
inverted (358). The ninth is the same rule written another way: sending
a missing badge event as an empty one. An empty event is never a
warning, so both answer that the badges draw the same hazard.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. The map's drawing, the alerts the badges name
and the closures the planning map passes stay in Swift. No network, no
user data.

## Reproduce

```sh
BASE=6343007 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header
(9acc14ae3829…). Run against a later commit, the same script checks the
facade: the Swift that now calls Rust must print the same bytes.
