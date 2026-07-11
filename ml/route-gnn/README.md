# FLOWS route-risk trainer (`ml/route-gnn`)

A **local, background worker** that builds up the on-device route-risk model from
the driver's own trips. It is self-contained in this folder and you launch it —
nothing in the app depends on it running (the app falls back to its statistical
seasonal prior when no trained model is present).

The trainer is **pure Rust, zero external crates** (`rust/flows-train`) — same
discipline as `flows-core`. The whole program stays **Rust + Assembly + Swift**;
there is no Python in the pipeline.

## What it does

1. Reads the app's flat training export
   `~/Library/Application Support/flows_training_export.csv`
   (real, decaying-weighted per-route/week observations the FLOWS app writes on
   each completed trip) **plus** low-weight physical seed rows (baked into the
   trainer: cold-season northern risk + a tropical bump for southern coasts).
2. Fits a small MLP `features → risk (0…1)` by Adam.
3. Writes the trained weights to
   `~/Library/Application Support/flows_route_head.json`,
   which the FLOWS app loads on its next launch and uses to **refine** the
   ranking prior (`SeasonalRiskModel.priorForRanking`). Confidence stays gated by
   how much *real* data backs each route, so a fresh model never overreaches.

The forward pass runs **in Swift** (`LearnedHead`) — this net is deliberately
tiny (6 features → 16 hidden → 1), where the ANE gives no benefit. The ANE/NPU
comes in at **phase 2b** (the graph net over hubs/edges).

## Feature contract (keep both sides in sync)

`rust/flows-train`'s `features(...)` stays **equivalent** to Swift
`RouteFeatures.vector`:

```
[ sin(2π·week/52), cos(2π·week/52), oLat/90, dLat/90,
  min(haversine_km(o,d), 4000)/4000, crossCountry ]
```

## Run it

Needs only the Rust toolchain (already used by the app build). No pip, no venv.

```bash
cd ml/route-gnn
./run_worker.sh --once     # build + train once now
./run_worker.sh &          # background: retrain weekly (logs/worker.log)
```

Weekly, unattended, via launchd:

```bash
sed "s|__DIR__|$(pwd)|g" com.flows.routegnn.plist.template \
  > ~/Library/LaunchAgents/com.flows.routegnn.plist
launchctl load ~/Library/LaunchAgents/com.flows.routegnn.plist
```

`FLOWS_GNN_INTERVAL` (seconds, default `604800` = 1 week) overrides the cadence.

## Privacy

`models/`, `logs/`, `data/`, and every `*.json`/`*.csv` here are **git-ignored** —
the training export mirrors the driver's own trip origins/destinations (personal
location history) and must never reach the repo or the shared mirror. The model
and all data stay on this device.

## Phase 2b — the ANE graph net (next)

Nodes = intersections (hubs), edges = roads. A message-passing GNN
(GraphSAGE-style k-hop aggregation) predicts per-edge risk/delay, generalizing to
roads you *haven't* driven from similar nearby ones, fusing historical + current
patterns. To run on the Neural Engine the model must be Core ML. Two in-stack
options that keep Python out: train the GNN in Rust (weights) and run the forward
pass in **Swift via `MLTensor`/BNNS** on the ANE, or author/train it with **Swift
Create ML**. The hub/edge history the app already accumulates
(`SeasonalStore.recordEdges`) is the training substrate.
