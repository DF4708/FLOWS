# Frozen Swift oracle: the risk advice and the border lines

`../../fixtures/swift_risk_advice_oracle.tsv` was produced by compiling the
ORIGINAL `RiskAdvice` (`RiskAdvice.swift`) at 3d08766, the last commit
before the facade switch, with this harness, and recording its output.
`../../swift_risk_advice_oracle.rs` checks the Rust against it.

## What it pins

43,572 records.

- `a` (1,636): `actions(kindName:band:)` for the 17 hazard names, names
  near them or the same name another way (every case, padding, a dotted
  or Kelvin letter, a combining mark, NUL, the empty name), and 300
  random names, each at the four bands.
- `g` (41,936): `isNorthOfTheBorder`, `isCanadaBelowTheBands`,
  `isAcrossTheBorder`, `mayBeAcrossTheBorder`, `officialURL` and
  `usSouthernBorderLat` for one point. Every band edge and box edge
  against every threshold latitude, each with the doubles just above and
  below and a quarter degree either side (the margin the "may be" test
  reads by); the US-Mexico line, the Rainy River and the St. Lawrence in
  small steps, on the line, a hair, a tenth and a quarter degree either
  side; every vertex and edge middle of the four outlines (Maine,
  Southeast Alaska, southern Ontario, Vancouver Island) and 400 random
  points in each one's box; NaN, the infinities, both zeros, 1e300 and
  the smallest doubles; real towns on both sides of each border; and
  4,900 random points across North America, denser where the lines are.

## What it found

The Rust matched the fixture on its first run. The advice name is read the
way Swift did, through `swift_text`: the standard library's `lowercased()`
and `==`. The page addresses are written with `swift_text::fixed`, which
prints what `String(format: "%.3f")` and `"%.4f"` printed.

Thirty-five changed rules were tried against the fixture before the facade
switch. Thirty-three failed it:

- the advice: no clear-band lines (409 records), no lowercasing (753),
  green read as yellow (226), yellow as red (262);
- the northern line: Alaska's latitude (17), Southeast Alaska's top (48),
  the 49th parallel by `>=` (135), the Northwest Angle's box (7), the
  Rainy River's lift (224), Superior (77), Michigan (71), Ontario's south
  shore (34), Lake Ontario's east end (28), the St. Lawrence's slope
  (262), the 45th parallel (47), Maine inside out (1,314), one Maine
  vertex (9), the Maritimes (54), the Ontario box (81) and the Vancouver
  box (14) below the bands;
- the southern line: the Californias slope (13,133), the Sonora line's
  end (414), New Mexico's flat line (1,875), a Rio Grande segment by `<`
  (6), the river's last point read as its first (18,795), Mexico's
  western edge by `<=` (810), the Gulf's top (108);
- the "may be" test: a margin of 0.2 (872), the northern margin
  subtracted (1,994), the Detroit to Niagara box (28);
- the page: southern Ontario and Vancouver Island sent to the Weather
  Service (961), Canada's coordinates at four places (12,052), the
  Weather Service's at three (25,648).

Two survived, and each is the same rule written another way:

- the name compared by bytes instead of Swift's `==`: every advice name
  is ASCII, and after `lowercased()` the only scalars that decompose to
  ASCII are U+037E and U+1FEF, neither of which is in a name, so
  canonical equality is byte equality here (`swift_text::eq` is kept as
  the original's rule);
- the Vancouver box's top at 48.9 instead of 49.0: west of the Northwest
  Angle the line is the 49th parallel, so every point above 48.75 is
  already "may be across" by the quarter degree margin.

After the switch, twelve changed facades were run through this harness
against the switched Swift's own output. Eleven failed it: each band read
one code off (358, 394, 394 and 409 records), the name dropped (831), the
"may be" test answered by the plain one (6,018), the plain one by the
northern line (4,221), the page's coordinates swapped (41,927), the
"below the bands" test's (1,086) or the northern line's (11,094) swapped,
and the southern line asked for the negated longitude (22,807). The
twelfth is the same rule written another way: dropping the empty-text
guard on the page. Rust always answers an address, and `URL(string: "")`
is nil anyway.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. The `URL` type stays in Swift. No network, no
user data.

## Reproduce

```sh
BASE=3d08766 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs (one with `SWIFT_DETERMINISTIC_HASHING=1`) must be
byte-identical; the body's sha1 is in the fixture's header
(d4bd6b4abfd6…). Run against a later commit, the same script checks the
facade: the Swift that now calls Rust must print the same bytes.
