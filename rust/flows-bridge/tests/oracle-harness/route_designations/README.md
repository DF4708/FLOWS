# Frozen Swift oracle: the route designations

`../../fixtures/swift_route_designations_oracle.tsv` was produced by
compiling the ORIGINAL `SafestRoute`, `CheapestRoute`, `EfficientRoute`,
`TruckerDesignation` and `FastestRoute` (in `RouteService.swift`) at
ea53276, the commit that gathered the last of them out of the routes view
and the last before the facade switch, with this harness, and recording its
output. `../../swift_route_designations_oracle.rs` checks the Rust against
it.

## What it pins

2,038 records. A pick is the winning candidate's index; lists run from none
to seven routes.

- `sf` (300): "Safest": lists not fully scored, a single route, every
  route the same risk, ties for lowest, risks that are not a number;
- `ch` (400): "Cheapest": fuel costs within a cent, exactly a cent and
  exactly the $5 toll allowance apart, tolled and toll-free, walks, costs
  that are not a number;
- `ef` (200): "Efficient": equal lengths, walks, odd lengths;
- `tr` (400): the trucker badge: each route's score and the pick, with
  routes that cannot clear a known bridge, walks, equal scores and equal
  ETAs;
- `fe` (150): the shortest ETA on offer, with none, and with ETAs that are
  not a number first and later;
- `cm`, `kp` (294 each): minutes behind the fastest for the chip and for
  the key point, on and either side of 30, 60 and 90 seconds.

Inputs where the original trapped (a gap too large for an integer) are not
in the fixture; the Rust answers them with the largest integer, pinned by
its own unit tests and by `RouteDesignationTests`.

Thirteen changed comparisons (inclusive ties, the cent, the allowance, the
toll tie-break, the bridge filter, rounding, the one-minute floor) each
break between 1 and 92 records. The first fixture missed the cent and the
allowance, having no costs exactly that far apart; it was frozen again with
them before the port was committed. Two changes are not caught because
they change nothing: comparing scores with "at least" where they are
already known to differ, and looking for a toll-free route when the lowest
already is one.

## What the harness never touches

Nothing is stubbed. The harness compiles the test target's own Core sources
as `project.yml` lists them at the base commit and links the Rust bridge
those sources already call. No network, no files, no user data.

## Reproduce

```sh
BASE=ea53276 bash build_and_run.sh   # builds outside the tree, runs three times, prints sha1 and counts
```

The three runs must be byte-identical; the body's sha1 is in the fixture's
header. Run against a later commit, the same script checks the facade: the
Swift that now calls Rust printed the same bytes (sha1 07bd89f2dce1…) on
the day of the switch.
