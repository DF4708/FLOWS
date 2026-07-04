# Routing checkpoints

Immutable copies of the routing implementation at known-good milestones.
The CONUS expansion work uses these as rollback anchors when an
experiment introduces a regression.

## Layout

```
R/checkpoints/
├── README.md                                  ← this file
├── .git-sha                                   ← commit SHA at snapshot time
├── .snapshot-utc                              ← ISO-8601 UTC timestamp
├── .sha256sums                                ← content hashes
├── route.R.wisconsin-baseline                 ← R/route.R at baseline
└── route_pathfind.R.wisconsin-baseline        ← R/route_pathfind.R at baseline
```

## What the Wisconsin baseline is

State of routing when the user confirmed *"the current routing works as
expected"* and requested a checkpoint before CONUS work began. The
baseline represents:

- A* pathfinder using OSM's Wisconsin road network (~90k edges, ~97k
  nodes after `ROUTE_NODE_SNAP_METERS` snapping).
- Three profiles: `fastest`, `safest`, `metro/metrorail`.
- Static `base_speed_mph` per road tier + a 5 mph safety-risk penalty
  (`adjusted_route_speed_mph`) applied when segment risk exceeds
  `RISK_RED_MIN`.
- No real-time traffic input to ETAs (511WI travel-times were
  deliberately excluded from risk during the safety-vs-throughput audit;
  they've never fed the ETA path).
- Sub-second latency on typical intra-Wisconsin routes.
- No hierarchical acceleration — pure Dijkstra/A\* on the flat edge
  table, which is why cross-state routing is currently impractical.

## How to restore

If any experiment in the CONUS expansion breaks routing, restore the
baseline in-place:

```bash
cp R/checkpoints/route.R.wisconsin-baseline           R/route.R
cp R/checkpoints/route_pathfind.R.wisconsin-baseline  R/route_pathfind.R

# Verify integrity
shasum -a 256 -c R/checkpoints/.sha256sums
```

Then re-run `tests/sqa_runner.R` + `tests/test_modeled_road_risk.R`
to confirm behaviour matches the baseline SQA outcomes.

## When to add a new checkpoint

Add a new checkpoint (`route.R.<name>-baseline` etc.) whenever:

- A phase of the CONUS expansion lands and passes its acceptance gate.
- Any breaking change to the routing API is about to be attempted.
- A hierarchical routing structure (contraction hierarchies, ALT, hub
  labels) is introduced.

The old checkpoints are **never deleted** — they form the reversible
timeline the testing strategy relies on.
