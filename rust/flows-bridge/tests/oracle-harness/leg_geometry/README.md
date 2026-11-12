# Frozen Swift oracle: the geometry of one leg

`../../fixtures/swift_leg_geometry_oracle.tsv` was produced by compiling
the ORIGINAL `LegGeometry` (`LegGeometry.swift`) at 231ef58, the commit
that gathered the rules out of `NavigationEngine` and `RouteService` and
the last before the facade switch, with this harness, and recording its
output. `../../swift_leg_geometry_oracle.rs` checks the Rust against it.

## What it pins

4,815 records.

- `leg` (81): legs built from their steps, with the meters to each point
  and where each step ends: no steps, only empty steps, one point, a leg
  standing still, long roads with stretches that stand still and roads
  that come back over themselves, short grid paths whose points repeat,
  rulers of equal hops, and one leg built so a fix is exactly 250 m from
  its first point;
- `mt` (1,501): the point a fix is matched to, read in the window around
  the last match and over the whole leg when the window lost the vehicle:
  fixes on and beside the 250 m where the window is lost, last matches on
  and beside both window edges, stale and past-the-end last matches, fixes
  that are not numbers, and one fix exactly 250 m off the window's best;
- `pg` (1,200): where the drive stands at a matched point: the step moved
  on at each step's end and never past the last, the meters to the turn,
  along and left, the share left, and the step's length; points the leg
  does not hold;
- `ah` (700): the first point far enough ahead, with meters exactly the
  meters to a later point and one bit either side, below zero and not
  numbers;
- `rw` (52): the wait before asking for a new road again, from -100,000
  failures to 100,000;
- `sm` (500): where the steep signs stand, with grades on and beside 6% and
  -6%, ends that are not numbers, profiles longer than the twelve signs
  shown, and stretches whose miles are exactly the meters to a point;
- `ct` (81): every leg's path cut at half its length, a path standing
  still among them;
- `cp` (700): check points with spacings exactly the meters to a point,
  added up hop by hop, and one bit either side; spacings of zero, below
  zero and not numbers.

## Mutation check

Fifty-eight mutants of `flows_core::leg_geometry` were run against this
fixture before it was frozen. Fifty break records. The eight that do not
cannot change an answer:

- `at_least_zero` with `>` for `>=`, which differs only for -0.0, and no
  difference of two meters is -0.0;
- the distance with its two points swapped, in the window scan and in the
  meters added up to each point: `POIRanking.meters` is exact under the
  swap;
- the meters left and the meters to the turn without their floor at zero,
  and the step's length with one: the meters to each point never go
  down, and the turn is never behind the matched point once the step has
  moved on;
- the wait capped with `f64::min`, which differs only for a wait that is
  not a number, and 15 times a power of two never is;
- the twelve-sign cap read after the grade instead of before: the same
  list.

The fix exactly 250 m off, the stretches exactly on a point and the leg
standing still were added to kill the three mutants the earlier runs left
standing: the window lost at `>=` 250 m, the steep search at `>` and the
cut at `>=` on a hop of zero length.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. No network, no files, no user data.

## Reproduce

```sh
BASE=231ef58 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs must be byte-identical; the body's sha1 is in the fixture's
header. Run against a later commit, the same script checks the facade: the
Swift that now calls Rust must print the same bytes.
