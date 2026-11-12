# Frozen Swift oracle: the live corridor watch's rules

`../../fixtures/swift_corridor_watch_oracle.tsv` was produced by compiling
the ORIGINAL `CorridorWatchRules` at 7c34c97, the commit that gathered the
rules out of `AppModel` and `WeatherAlertService` and the last before the
facade switch, with this harness, and recording its output.
`../../swift_corridor_watch_oracle.rs` checks the Rust against it.

## What it pins

1,500 records, every number bit for bit, every index and flag exactly.

- `win` (200): the lookahead and the refresh cadence for a speed, on and
  either side of the 3 and 20 meters-a-second steps and the 5 km and 150 km
  ends, and for speeds that are negative, infinite or not a number;
- `spm`, `mph` (150 each): the route's pace and its average speed, with
  zero, negative, huge and not-a-number distances and durations;
- `sl` (400): which check points a pass looks at and when each is reached:
  the vehicle before, on and past the route, lookaheads from none to
  endless, backwards windows (the pass is then every check point), odd
  spacings. A pass over every check point prints `-` for its bounds;
- `rd` (200): the mean, the worst check point and which one it is, with
  none, ties, and not-a-number readings first and later;
- `fd` (400): which window check point repaints each route check point:
  window points on, near (up to and past 600 m) and far from the route,
  two route points at one place, readings exactly 0.02 off and a hair past
  it, alerts that differ only in event, only in id, or only as nil versus
  empty text, and several window points landing on one route point.

Inputs where the original trapped (a check-point index that is not a
number, a route with no check points) are not in the fixture; the Rust
answers them as "every check point", pinned by its own unit tests and by
`CorridorWatchRulesTests`.

Changing the match distance comparison, the repaint margin comparison, the
first-of-equal-worst rule or the slice clamp each breaks between 5 and 56
records.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. No network, no files, no user data.

## Reproduce

```sh
BASE=7c34c97 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs must be byte-identical; the body's sha1 is in the fixture's
header. Run against a later commit, the same script checks the facade: the
Swift that now calls Rust printed the same bytes (sha1 05e07a25a743…) on
the day of the switch.
