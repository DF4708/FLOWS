<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — documentation index

Everything a maintainer needs to work on FLOWS. Read in this order.

## 1. [ARCHITECTURE.md](ARCHITECTURE.md)

The map. Layers, module structure, data flows, cache tiers, external
feeds, routing pipeline. Start here if you don't know where something
lives.

## 2. [LEARNINGS.md](LEARNINGS.md)

Non-obvious facts, footguns, and design principles discovered while
building the current codebase. Read this before you touch anything —
if a change to the codebase violates one of these principles, expect
a regression.

## 3. [TESTING_STRATEGY.md](TESTING_STRATEGY.md)

The scientific-method framework for the CONUS expansion. Every
routing / map change during the CONUS work runs through the harness
described here. Regression gates, latency budgets, correctness gates,
rollback protocol.

## 4. [CONUS_EXPANSION.md](CONUS_EXPANSION.md)

The migration plan from Wisconsin-only to the whole continental US.
Enumerates every Wisconsin-hardcoded piece; proposes a four-phase
rollout; specifies the hierarchical-routing algorithm required for
cross-country A\*.

## 5. [MOBILE_PACKAGING.md](MOBILE_PACKAGING.md)

Three paths to iOS / macOS / iPadOS deployment (WKWebView wrapper,
Capacitor hybrid, native Swift). Includes the Critical Alerts
entitlement application path and turn-by-turn navigation safety
requirements.

## 6. [APPLE_APP.md](APPLE_APP.md)

The native Swift app (`apple/`) — the "native Swift" path from
MOBILE_PACKAGING.md, built. SwiftUI + MapKit across macOS/iOS/iPadOS,
MKDirections NA-wide routing with FLOWS corridor weather scoring,
dynamic-zoom turn-by-turn navigation, CarPlay + Apple Music stubs, and
the Rust/assembly core bridge. Build, architecture, and roadmap.

## Companion directories

- `../R/checkpoints/` — immutable snapshots of routing at known-good
  milestones. Rollback anchor for any CONUS experiment that
  regresses. See `../R/checkpoints/README.md`.
- `../tests/` — regression suite (`sqa_runner.R`, `mutation_test.R`,
  `test_modeled_road_risk.R`, `static_analysis.R`, `score_matrix.R`)
  plus the CONUS experiment harness
  (`conus_experiment_harness.R`) and the append-only log
  (`experiments.jsonl`).
