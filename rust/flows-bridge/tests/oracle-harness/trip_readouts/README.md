# Frozen Swift oracle: the trip readouts

`../../fixtures/swift_trip_readouts_oracle.tsv` was produced by compiling
the ORIGINAL `TripReadouts` (`TripReadouts.swift`) at 1cc992f, the commit
that gathered the readout numbers out of the views and the last before the
facade switch, with this harness, and recording its output.
`../../swift_trip_readouts_oracle.rs` checks the Rust against it.

## What it pins

2,609 records, numbers only (the words stay in Swift).

- `tf` (397): feet to a close turn, on and beside the 0.19-mile cut-off and
  the halves of the 50-foot step, with distances below zero;
- `mp` (300): digits after the point for the card and for the planner, on
  and beside 9.95 and 10 miles, and the miles themselves;
- `sm` (389): what Siri says: "1 mile", whole miles, tenths, on and beside
  the halves that round a tenth;
- `mn` (246): whole minutes, on and beside the half minute, below zero;
- `ck` (392): a time as minutes, hours and minutes, or days, on and beside
  90 minutes and two days, with and without days;
- `ms` (240): minutes a faster road saves, never below 1;
- `xp` (245): the share and the miles of a route inside alert areas;
- `gr` (400): the grade at a mile, over tables whose stretches touch,
  overlap, leave gaps, run backwards or hold numbers that are not numbers.

Inputs where the original trapped (a number that is not finite, or too
large, turned into an integer) are not in the fixture. The Rust answers
them with 0 for not-a-number and the largest integer for too large, pinned
by its own unit tests and by `TripReadoutsTests`.

Twenty-two changed comparisons and roundings were tried against the fixture
before it was frozen. Twenty-one each break between 1 and 290 records. One
is not caught because it changes nothing: at exactly ten miles the spoken
distance is "10 miles" by either branch.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. No network, no files, no user data.

## Reproduce

```sh
BASE=1cc992f bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs must be byte-identical; the body's sha1 is in the fixture's
header. Run against a later commit, the same script checks the facade: the
Swift that now calls Rust printed the same bytes (sha1 0d2f8fbd11af…) on
the day of the switch.
