# Frozen Swift oracle: the map sweep's per-point rules

`../../fixtures/swift_viewport_point_oracle.tsv` was produced by compiling
the ORIGINAL `ViewportPointRules` (`ViewportPointRules.swift`) at 6a716f6,
the commit that gathered the rules out of the map view and the last before
the facade switch, with this harness, and recording its output.
`../../swift_viewport_point_oracle.rs` checks the Rust against it.

## What it pins

3,600 records.

- `df` (1,200): the families that show at a point, or that the point does
  not show: forecast families under live readings, on and beside the 0.25
  show floor, with and without an air reading, with quiet points;
- `pt` (2,400): the families with a closure added, the band's input and
  what names the badge (a family, rain chance, the forecast, the alert, a
  closure): scores on and beside every floor (0.45 to name, 0.6 for an
  alert, Yellow for a realized primary, 0.8 for a closure), families that
  tie, the flood family in front with the gauges on and beside 0.45, the
  blended composite in front, alerts for primary and predictor families,
  and family names the tables do not hold.

Scores that are not numbers, endless or below zero are in both kinds.

Forty-seven changed floors, comparisons and rules were tried against the
fixture before it was frozen. Each breaks between 1 and 1,482 records. The
first draw let two through (the cut-off that tells a flood from rain chance
was met too rarely), so the generator was given a case for it and the whole
list was run again.

## One rule is new at the base commit

When two realized primaries tie for the worst, the lower family name names
the badge. Before 6a716f6 the name followed Dictionary order, which changes
between launches, so no oracle could pin it.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. No network, no files, no user data.

## Reproduce

```sh
BASE=6a716f6 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs must be byte-identical; the body's sha1 is in the fixture's
header. Run against a later commit, the same script checks the facade: the
Swift that now calls Rust printed the same bytes (sha1 97c05ab0d3e3…) on
the day of the switch.
