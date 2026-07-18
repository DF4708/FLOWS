<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — R → Rust core + Swift UI migration (architecture decision record)

The user proposed: *"It doesn't have to be an R project if we can convert
it to Rust and Assembly, with Swift for UI."* This ADR gives the honest
assessment — where each technology genuinely fits, where it doesn't, and a
phased plan that never loses the working R app as the correctness oracle.

Status: **PROPOSED** — toolchains verified present (rustc 1.93, cargo 1.93,
Swift 6.3.3, clang 21). No production code migrated yet; a proof-of-concept
crate proves the path.

---

## 1. The verdict, up front

| Technology | Verdict | Where it fits |
|---|---|---|
| **Rust** | ✅ Strong yes | The entire compute core — feed fusion, scoring, geometry, routing. Memory-safe, fearless concurrency, C-ABI FFI, mature geo + graph crates. |
| **"Assembly"** | ⚠️ Redirect | **Not** hand-written assembly for the app. Rust already compiles to optimized machine code. For the 2-3 proven hot kernels, use **SIMD intrinsics** (`std::simd` / ARM NEON) — 95% of the win, portable, maintainable, still "down to the metal". Hand-assembly only if a profiler proves a specific kernel is the bottleneck AND the compiler demonstrably leaves performance on the table (rare). |
| **Swift / SwiftUI** | ✅ Strong yes | The native UI for iOS / macOS / iPadOS. MapKit for the map + turn-by-turn, CoreLocation for GPS, UserNotifications for the life-threatening-alert push. Calls the Rust core over a C ABI (or UniFFI for ergonomics). |

The coherent target architecture:

```
┌──────────────────────────────────────────────────────────────┐
│  SwiftUI app (iOS / macOS / iPadOS)                           │
│  ├── MapKit map + MKDirections-style turn-by-turn            │
│  ├── CoreLocation (background GPS)                            │
│  ├── UserNotifications + Critical Alerts                     │
│  └── AVSpeechSynthesizer (voice guidance)                    │
└──────────────────────────┬───────────────────────────────────┘
                           │  C ABI / UniFFI  (in-process, zero network)
                           ▼
┌──────────────────────────────────────────────────────────────┐
│  flows-core  (Rust static/dynamic library)                    │
│  ├── feeds    — async HTTP (reqwest/tokio), JSON (serde)      │
│  ├── scoring  — the noisy-OR family model, risk bands         │
│  ├── geo      — geometry (geo/geos-rs), spatial index (rstar) │
│  ├── routing  — contraction hierarchies (fast_paths crate)   │
│  │              CONUS-scale, the whole reason to leave R      │
│  ├── kernels  — SIMD distance matrices (std::simd / NEON)    │
│  └── ffi      — #[no_mangle] extern "C" exports              │
└──────────────────────────────────────────────────────────────┘
```

This is exactly the shape modern navigation apps take (Valhalla/OSRM are
C++ cores behind native UIs; Rust is the memory-safe equivalent).

---

## 2. Why leave R at all

R was the right choice for the *prototype*: fast to write, `sf` gives
world-class geometry, rich stats. But three walls appear at CONUS scale:

1. **Routing.** R's flat-table Dijkstra/A\* is ~3 orders of magnitude too
   slow for a 30M-edge CONUS graph (documented in `CONUS_EXPANSION.md §3`).
   The fix — contraction hierarchies — is a systems-programming problem.
   Rust's `fast_paths` crate does exactly this and is production-grade.
2. **Memory + concurrency.** R's copy-on-modify + fork-based parallelism
   fights the 90% memory ceiling (see `LEARNINGS.md §9`). Rust's ownership
   model + `rayon`/`tokio` give bounded-memory, work-stealing parallelism
   without the fork-RSS-copy problem.
3. **Deployment.** R can't ship inside an iOS app. A Rust static library
   links directly into the Swift binary — one process, no server round-trip,
   works offline. That is the entire value of the mobile target.

R does **not** go away during the migration — it becomes the **reference
oracle**. Every ported Rust module is verified byte-identical against the R
implementation before it replaces it (the equivalence-test discipline we
already use for the vectorised refactors).

---

## 3. On "Assembly" specifically — the honest engineering answer

Writing an application in assembly is not a real option in 2026 — it would
be unmaintainable, non-portable across the Apple ARM64 + any x86 CI, and
*slower* than what LLVM produces for 99% of code, because the compiler
schedules instructions and allocates registers better than a human can at
scale.

What the user is *actually* reaching for — maximum performance on the hot
math — is real and achievable the right way:

- **SIMD intrinsics.** The dense Euclidean distance matrices (already
  isolated behind `euclidean_distance_matrix` in R) are pure data-parallel
  float math — the ideal SIMD target. In Rust: `std::simd` (portable) or
  `core::arch::aarch64` NEON intrinsics (Apple-specific). This processes
  4-8 lanes per instruction — the "assembly-level" speedup, but readable and
  verified.
- **Auto-vectorization.** Rust + LLVM already auto-vectorizes tight loops
  with `-C target-cpu=native`. Often you get SIMD for free.
- **GPU offload.** For the truly large matrices (CONUS-scale proximity, CH
  preprocessing), the 32 Metal GPU cores via `wgpu` or `metal-rs` beat any
  CPU SIMD. This is the same seam the R `compute_backend()` already models.
- **Profile first.** Hand-assembly is only justified if `cargo flamegraph`
  proves a specific kernel dominates AND the SIMD version still leaves cycles
  on the table. That has not happened for any FLOWS kernel and likely never
  will. We write the SIMD kernel, measure it, and only descend to `asm!`
  blocks if the numbers demand it — never speculatively.

**Decision:** "Rust + Assembly" is implemented as **Rust with SIMD
intrinsics for proven hot kernels, GPU for the largest, and inline `asm!`
only where a profiler mandates it.** The shipped example is the polyline
varint decoder's AArch64 `asm!` kernel (`decode_deltas_asm`), held
byte-identical to a portable Rust oracle — a real on-device integer hot loop,
not a speculative one. The distance kernel stays the scalar reference (it runs
only on the R bridge); its SIMD form drops in behind the same signature if a
profile ever shows it dominating.

---

## 4. The FFI boundary — how Swift calls Rust

Two options, both proven:

1. **Raw C ABI** (`#[no_mangle] extern "C"`). Rust exposes plain C
   functions; a hand-written bridging header lets Swift call them. Minimal
   dependencies, maximum control, but you marshal structs by hand.
2. **UniFFI** (Mozilla). Generates the Swift bindings from a Rust interface
   definition — enums, structs, `Result`, async — ergonomically. More
   dependency weight, far less boilerplate.

**Decision:** start with **raw C ABI** for the PoC (smallest surface, proves
the link works), migrate to **UniFFI** once the interface stabilises and the
struct-marshalling boilerplate becomes the cost.

The library builds as a `staticlib` (`crate-type = ["staticlib"]`) →
`libflows_core.a` → linked into the Swift app. For macOS/iOS universal
binaries, build for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and
`aarch64-apple-darwin` and `lipo` them into an `.xcframework`.

---

## 5. Phased migration (keeps R as oracle throughout)

Each phase ports a slice, verifies byte-identical output against R, then
retires the R slice. No phase begins until the previous passes its
equivalence gate.

### Phase R0 — proof of concept (this ADR's companion code)

- Cargo workspace `rust/` with `flows-core`.
- Port the *pure, side-effect-free* functions first: `risk_label_from_score`,
  `risk_rgb_hex`, and the Euclidean distance kernel (scalar reference).
- A Rust test suite that reproduces the R SQA boundary cases exactly.
- A C-ABI export + a Swift snippet that calls it and prints the result.
- **Gate:** Rust output byte-identical to R for every SQA boundary case.

### Phase R1 — scoring core

- Port the family scoring (`compute_driving_risk`, the noisy-OR combine,
  the 511 safety-vs-throughput scorers). These are pure and heavily
  test-covered — ideal to port with the mutation harness as the oracle.
- **Gate:** all 13 mutation cases + 8 SQA suites reproduced in Rust.

### Phase R2 — feeds

- Port the HTTP feed clients (NWS, NWPS, WPC, 511, …) using `reqwest` +
  `serde`. Async via `tokio`. The R fork-safety learnings become Rust's
  trivially-safe async tasks.
- **Gate:** for a captured fixture set of raw feed payloads, Rust produces
  the same parsed/scored per-ZIP frame as R.

### Phase R3 — geometry + routing (the payoff)

- Port geometry to `geo` + `geos-rs`; spatial index via `rstar`.
- Implement CONUS routing with `fast_paths` contraction hierarchies.
- **Gate:** route quality parity on the 100-route corpus (same gate as
  `CONUS_EXPANSION.md` Phase 3) AND cross-country p95 ≤ 4 s.

### Phase R4 — Swift UI

- Replace Shiny + Leaflet with SwiftUI + MapKit.
- Wire CoreLocation, UserNotifications (Critical Alerts), AVSpeechSynthesizer
  per `MOBILE_PACKAGING.md`.
- **Gate:** feature parity with the R/Shiny map + the mobile safety
  requirements.

---

## 6. Timeline honesty

This is a **months-long** effort, not a session:

- Phase R0 (PoC): days.
- Phase R1 (scoring): 2-3 weeks.
- Phase R2 (feeds, 20+ integrations): 4-6 weeks.
- Phase R3 (geometry + CH routing): 6-10 weeks — the hardest.
- Phase R4 (Swift UI + mobile): 8-12 weeks + Apple review.

Total realistic: **6-9 months** to a shipped native app. The R app keeps
running and improving (CONUS Phase 1 is already underway) the entire time,
so there is never a period without a working product.

---

## 7. What must NOT be lost in translation

Every learning in `docs/LEARNINGS.md` is a bug the R code already paid for.
The Rust port must preserve the *behaviour*, verified by the oracle:

- Safety-vs-throughput discipline (operational text scores 0).
- Sanitiser boundaries (no travel-delay text in popups).
- The band thresholds (`RISK_GREEN_MIN` etc.) exactly.
- The degraded-snapshot guard (no NA-temperature ZIPs).
- The memory ceiling (Rust makes this *easier* — bounded allocation).

Rust's type system will catch several of these at compile time that R only
caught at runtime (the `nzchar(NA)` class of bug simply cannot happen with
`Option<&str>`). That is a reason to port, not just a risk to manage.

---

## 8. Decision

**Adopt the Rust-core + Swift-UI target architecture.** Implement
"assembly" as SIMD intrinsics + GPU for proven hot kernels, not hand-written
assembly. Keep the R app as the correctness oracle and the shipping product
until each Rust phase passes its equivalence gate. Begin with the Phase R0
proof-of-concept crate under `rust/`.

## Phase R-route — the CONUS router (started)

The single biggest CONUS win is replacing the per-request routing (R A* /
optional cppRouting) with a Rust contraction-hierarchy (CH) router so
cross-country queries touch O(log n) of the graph, not all of it.

**Foundation landed (`flows-core/src/routing.rs`):** a pure-std Dijkstra over a
CSR (compressed-sparse-row) directed weighted graph — `CsrGraph { offsets,
targets, weights }` with `dijkstra(source)` and early-exit `shortest_distance
(s, t)`. Verified against a known-answer reference graph (cargo test). No
external crate yet (builds small under the memory ceiling).

**Why CSR:** cache-friendly, O(1) neighbour scan, and it's exactly what an R
edge list (from/to/weight) marshals into. Graph topology (offsets+targets) is
shared across the three profiles; only the `weights` vector differs per profile
(fastest/safest/metro), so profiles reuse the structure. Risk penalties are
*added* to travel time, keeping weights non-negative (Dijkstra/CH requirement).

**Remaining steps (each behind an equivalence gate vs the R/cppRouting oracle):**
1. FFI ingest: build a `CsrGraph` from R's edge table via `.C`/pointers; return
   distances/paths. Prove byte-identical distances vs the R A* on the WI graph.
2. Node ordering + CH preprocessing (add the `fast_paths` crate, or hand-roll a
   witness-search contraction) — precompute shortcuts once per topology.
3. CH query; prove same shortest costs as the plain Dijkstra above (paths may
   differ on ties — compare COST, and unpack a valid path).
4. Measure query latency vs cppRouting/A* at WI scale (parity expected) and
   project CONUS (where CH's O(log n) is the whole point). Gate on parity + no
   regression before flipping the production route planner, R fallback intact.

### R-route phase 2 — contraction hierarchies (design)

Ingest is done (`flows_dijkstra_c`, byte-identical to R Dijkstra, 300/300 random
graphs). Next is CH preprocessing so a query touches O(log n) of the graph.

**Node ordering (importance).** Contract nodes least-important-first. Importance
per node ≈ edge-difference heuristic: `(shortcuts_added − edges_removed)` if it
were contracted now, plus tie-breakers (contracted-neighbours count, level) to
spread contractions spatially. Maintain a priority queue keyed on importance;
lazy-update the top node's importance before contracting (recompute, and if it's
no longer the min, re-push and pick again).

**Contracting a node v.** For every pair of remaining neighbours (u, w) with
edges u→v→w, run a **witness search**: a limited forward Dijkstra from u
(bounded by `dist(u,v)+dist(v,w)`, hop/settled-node capped) to see if a path
u→…→w NOT through v is already ≤ that cost. If no witness, insert a shortcut
edge u→w with weight `dist(u,v)+dist(v,w)` (remembering the middle node v so the
path can be unpacked later). Store the node's contraction rank (`level[v]`).

**Query (bidirectional upward search).** From source run Dijkstra following only
edges to HIGHER-ranked nodes; same from target on the reverse graph. Settle when
the two searches meet; the shortest cost is the min over meeting nodes of
`dist_fwd + dist_bwd`. Unpack shortcuts recursively (each stores its middle node)
to recover the full path. Costs must equal the plain Dijkstra above (paths may
differ only on equal-cost ties).

**Data layout.** Keep the original CSR immutable; add a parallel "up-graph" CSR
(edges + shortcuts sorted so each node's higher-ranked neighbours are contiguous)
plus `level[]` and a `middle[]` array for shortcut unpacking. Preprocessing is
per-topology (shared across the 3 weight-profiles only if weights don't change
the topology — they don't; so preprocess ordering once, but shortcut WEIGHTS are
per-profile, recomputed when weights change). Weights stay non-negative.

**Gates (each before any prod flip):** (1) CH query cost == plain Dijkstra cost
on random graphs + the real WI graph; (2) unpacked path is valid + its summed
weight == the cost; (3) latency vs cppRouting/A* at WI (parity) and projected at
CONUS (where CH's O(log n) is the point). Prod route planner flips only when all
green, with the R A* fallback intact.

**Crate vs hand-roll.** Prefer the `fast_paths` crate (battle-tested CH) once a
low-memory build window allows adding it; the hand-rolled design above is the
fallback and the mental model for the equivalence gates either way.
