# Frozen Swift oracle: the planning map's risk-area geometry

`../../fixtures/swift_risk_area_fallback_oracle.tsv` was produced by
compiling the ORIGINAL `RiskAreaFallback` (`RiskAreaFallback.swift`) at
f7ea216, the last commit before the facade switch, with this harness, and
recording its output. `../../swift_risk_area_fallback_oracle.rs` checks the
Rust against it.

## What it pins

4,727 records.

- `z` (1,561): the ZIP box and the blob wait for all four
  (lookups done, placed before) pairs, at the box's edges and the two
  doubles either side of each, at random points across North America, and
  at the special values (NaN, the infinities, signed zeros, the smallest
  and largest doubles, ±90 and ±180);
- `l` (1,817): the sweep's lattice for map views like the app's, spans on
  a rung of the ladder exactly and one double either side, centers that
  put a bound on a multiple, zero and negative spans and the special
  values, with `perSide` from -3 to 12 (the app asks for at most seven);
- `c` (626): the circle drawn where no ZIP is, for random centers, radii
  from 1 m to 300 km and vertex counts from -5 to 100 (the default 32
  among them), at and past the poles, zero and negative radii and the
  special values;
- `r` (723): for each ring, the centroid, the icon anchor, the interior
  samples for limits -1, 0, 1, 2, 3, 5, 9, 16, 17 and the default, and
  the even–odd test for probes at the first eight vertices, their edge
  middles and the doubles beside them, the centroid, a 5 × 5 grid over and
  past the bounding box, and random points. The rings are stars, crescents
  (whose centroid falls outside), combs (whose middle line meets up to
  sixty edges), random rings, rings closed on their first point, rings
  with repeated vertices, rectangles both ways round, rings with no area
  or an area about the 1e-12 line, a bow tie, a pentagram and a
  heptagram, and rings with a special value in every place.

77 lattices are left out: the original never finishes them (a bound that
is infinite, or a multiple of the step past 2^53, where a step of one no
longer moves the index), so it cannot be asked. The harness skips them by
the original's own arithmetic. The Rust stops there instead (see
`flows_core::risk_area`).

## What it found

The circle is the one rule not pinned to the bit. Swift's Release build
fuses each vertex's `sin` and `cos` into `__sincos_stret`, which can be one
unit in the last place off the standalone calls; the Rust uses
`flows_core::fmath`. A circle vertex must match within two units in the
last place plus 1e-15 of the radius in degrees, far under a micrometre on
the ground, and a non-finite one must be non-finite the same way. On this
machine every vertex matched to the bit in both debug and release.

The rest are the same bits, which took Swift's own rules for its
helpers: `max(x, y)` answers `x` when `x` is NaN (Rust's `f64::max`
answers `y`), `min()` and `max()` over a sequence keep the first element
until a later one beats it, `reduce(0, +)` starts from +0.0 (Rust's `Sum`
starts from -0.0, which one record catches), and the rung's `pow(2, x)` is
`exp2` in Release. The icon anchor's crossings sort the way Swift sorts
them: below 64 elements Swift's sort is an insertion sort, which places a
NaN where a plain insertion sort does. Rust's own `sort_by` with a
NaN-tolerant comparator panics on those rings ("does not correctly
implement a total order"), so the Rust uses it only for 64 or more
crossings with no NaN, where every stable sort agrees.

Thirty-one changed rules were tried against the fixture before the facade
switch. Twenty-three failed it: the box's `>` as `>=` on the latitude (7
records) or `<` as `<=` on the longitude (7), the blob not waiting on
lookups (278) or on an earlier placing (278), the rung rounded down (871)
or raised by `e` instead of 2 (1,249), a zero span given a real rung
(102), the lattice's last row (310) or column (374) dropped, `perSide`
floored at 2 (558), the first row rounded down (1,250), a circle of at
least four (180), the cosine floored by Rust's `max` (9), a wider no-area
test (24), the vertex mean by `Sum` (1), the crossing test by `<` (16),
the widest stretch replaced on a tie (24), the anchor needing four
vertices (4), the stride rounded down (416), the grid a quarter in instead
of a half (591), the even–odd edge test by `>=` (273), its side test by
`<=` (659) and the samples needing only two vertices (1). The twenty-fourth,
Rust's `sort_by` for every ring, panicked.

One more, `contains` needing only two vertices, survived the fixture: a
two-point ring's two edges are one segment walked both ways and almost
always cancel. The test's second check, `a_ring_under_three_points_holds_nothing`,
probes on both crossings and the doubles next to them, where rounding puts
them an ulp apart, and kills it.

Six more survived, and each is the same rule written another way:

- the circle's cosine as `sin(a + π/2)`: within the circle's tolerance;
- `3 * area + 0`: the same number for every area that passes the test;
- `<=` instead of `<` in the bounding box's `min()`, and the same in its
  `max()` (two of the six): they
  differ only on which signed zero comes back, and the grid's arithmetic
  gives the same points for either;
- the samples kept whole only below the limit instead of at it: at the
  limit the stride is exactly 1 and picks every sample in order;
- no special case for a limit of 1: the stride is then infinite, its
  first index NaN, and Rust's saturating cast reads that as 0, the same
  first sample. (Swift's `Int(NaN)` traps, which is why the original has
  the case; the Rust keeps it.)

After the switch, six changed facades were run through this harness against
the switched Swift's own output, and all six failed it: a ring sent
longitude first (705 records), points read back longitude first (2,689), a
circle's default of 33 vertices (117), a samples default of 8 (260), a
lattice with one more point per side (802) and `contains` sent the probe's
longitude and latitude swapped (638).

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. The ZIP lookups, the map's drawing and the
alerts that call `contains` stay in Swift. No network, no user data.

## Reproduce

```sh
BASE=f7ea216 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header
(c153cb2a2462…). Run against a later commit, the same script checks the
facade: the Swift that now calls Rust printed the same bytes on the day of
the switch, except circle vertices, which the Rust test's tolerance
covers.
