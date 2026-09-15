<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
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

Status: **DONE — this ADR's plan was executed and superseded.** As of
2026-07-19 the migration is complete: the R/Shiny engine is fully retired
(commit c8a903e), the app ships as native Rust + Swift, and the risk/scoring
paths are pinned byte-identical to frozen fixtures captured from the R oracle
before it was removed. One prediction here was **overturned by measurement**:
this ADR recommended SIMD intrinsics over hand-assembly and cautioned that
raw `asm!` is rarely justified. A hand-written AArch64 varint kernel was in
fact written and shipped — then **retired on 2026-07-19** when the bake-off in
`rust/flows-core/src/bin/bench.rs` showed rustc's portable raw-pointer code
*faster* than the hand kernel (2.59 vs 3.20 ns/byte). The doctrine below held:
assembly must beat the compiler to earn its place, and it didn't. FLOWS now
ships **two** languages, Rust + Swift. The rest of this document is preserved
as the original decision record.

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

## The Swift boundary: closed, and how it reopens (2026-09-09)

`flows-core` is `#![forbid(unsafe_code)]` with no carve-out, and there is
zero `unsafe` anywhere in project-controlled Rust. Both facts are enforced by
the compiler, not by review: a control test confirms the lint fires on an
`unsafe` block *and* on a `#[no_mangle]` declaration.

### Why there is no FFI module at all

`#[no_mangle]` is itself rejected by `forbid(unsafe_code)` — the lint treats
manual symbol export as an unsafe capability. So a C-ABI export and a
forbidden crate cannot coexist. That forced the question of what the exports
were actually worth, and the answer was: nothing.

- `flows_risk_label`, `flows_distance_matrix`, `flows_dijkstra_c`,
  `flows_ch_query_c`, `flows_ch_path_c` — zero references in the Swift app.
- `flows_polyline_decode` — the Swift caller already carried
  `decodePolylineSwift`, a value-identical native decoder, as its fallback.
- `flows_transit_plan` — no caller; the Swift file's one mention is a comment
  saying it "goes live once GTFS timetables load".
- `flows_transit_selftest` — a diagnostic with no consumer outside the bridge
  file itself.

Deleting them removed, on the Swift side, a `dlsym` whose result was
`unsafeBitCast` into a function pointer, two `withUnsafe*BufferPointer`
scopes, and a copy of every decoded double out of a scratch buffer.

**This is the answer to "would moving the processing to Swift remove the
unnecessary copy?" — yes, completely, and better than a serialization
boundary would.** A serialization boundary replaces one copy with two. Having
no boundary has none. The measured price is about 23 microseconds on a 10 KB
route polyline: the Rust decoder runs at 1.16 ns/byte, the Swift one at 4.73
(both measured on the same corpus shape, `rust/flows-core/src/bin/bench.rs`
and the Swift harness in the session scratchpad). Four times per byte, and
immaterial per call.

### swift-bridge — verified, and the chosen mechanism for when transit lands

swift-bridge was tested against the actual requirement rather than assumed:

- It compiles under `#![forbid(unsafe_code)]`, including with the shape the
  transit engine needs (an opaque type, `&[u8]` in, `Vec<u32>` out). A
  control in the same crate proves the lint was live for that test.
- It exports through `#[export_name]` — 207 uses in `swift-bridge-ir`, and no
  `#[no_mangle]` — which is precisely why it survives `forbid` where a
  hand-written export cannot. Real symbols are emitted
  (`___swift_bridge__$Planner$plan`).
- Cost: one dependency whose transitive graph is the proc-macro chain
  (`proc-macro2`, `quote`, `syn`, `unicode-ident`), all build-time.

This is what §3.15 step 5 prescribes — "the smallest vetted capability
provider that exposes a safe Rust API" keeping unsafe outside
project-controlled Rust — so it is the mechanism of record. It is not being
adopted *today* because there is currently nothing to bridge: adopting it now
would add a dependency, a codegen step, and a build-time cross-compile for
two symbols with no callers. It goes in with the RAPTOR engine, which is
where Rust speed actually earns a boundary.

### NEON SIMD — ineligible under the standard, and it is not close

Requested, and it cannot be done as asked. Every `core::arch::aarch64` NEON
intrinsic is an `unsafe fn`, so a hand-written NEON kernel is unsafe Rust in
project-controlled source: forbidden by §3.15, forbidden again by §3.25.6
("Project-controlled Rust MUST NOT contain `asm!`, `global_asm!`, or any
other unsafe Rust path"), and forbidden by the standing instruction that none
of this may introduce unsafe code.

§3.25.6 does allow an unsafe-intrinsic kernel — but only through a vetted
dependency exposing a safe API, and only once §1.9 and §4.8 show that safe
Rust fails **a genuinely mandatory performance target**. There is no such
target here. The one hot loop that was ever a candidate is the polyline
decoder, and it has just been moved to Swift at 4.73 ns/byte because the
difference did not matter. Vectorizing a decoder we no longer call from the
app would be optimizing something off the critical path (§1.6).

If a mandatory target appears — a national-scale RAPTOR query budget is the
plausible one — the compliant ladder is: safe Rust first, then measure under
§4.8, then a vetted crate with a safe API, with the safe path kept as the
oracle. `std::simd` (portable, safe, currently nightly) would also become
eligible before any intrinsic kernel does.

## The R mathematics: what came across, and what is still split (2026-09-09)

There is no R left in the repository — the engine was retired in `c8a903e`,
forty files. The question that matters is not whether R lingers but whether
its mathematics did, and where it lives now.

### Ported to Rust this pass

`flows-core::families` is the port of `R/families.R`, and `flows-core::scoring`
gained the `R/forecast.R` predictors. Together that is the model the band cuts
sit on:

| Rust | R |
|---|---|
| `FAMILY_WEIGHTS`, `family_weight` | `environmental_family_weights` |
| `noisy_or` | `noisy_or_combine` |
| `realized_risk`, `PRIMARY_FAMILIES`, `SECONDARY_FAMILIES`, `SECONDARY_CEILING` | the primary/secondary model over that combine |
| `alert_family` | the NWS event-name classifier |
| `flood_elevation_multiplier` | the waterline-threshold flood amplifier |
| `ranking_risk` | the two-truths route ordering |
| `displayed_band`, `dominant_family`, `ACUTE_FAMILIES` | route band display and area naming |
| `wind_risk`, `pop_risk`, `forecast_composite`, `temperature_anomalous` | `R/forecast.R:226-228` |

Forty-one tests pin it, written as behaviour classes rather than examples:
predictors alone can never reach Red however many pile up; one realized
primary keeps its full severity; two independent primaries compound; families
in neither tier are ignored rather than defaulted; a Snow Squall Warning is
not downgraded by the word "snow"; an Ashfall Advisory stays Red-incapable
while an eruption does not.

### Two defects the port surfaced

**The trainers asserted an R-derived invariant against a copy of it.** Both
`history-baseline` and `national-bundle` cap their scores below the app's
yellow cut and checked that with a bare `0.699` literal — four copies of a
constant that lives in `flows-core::RISK_YELLOW_MIN`, in a crate they did not
depend on. Move the cut and every assertion still passes while priors quietly
begin reaching yellow. `flows-train` now depends on `flows-core` (a
workspace-internal crate, so the zero-external-crates discipline is intact)
and asserts against the constant.

**The Swift implementation is not reproducible.** `realizedRisk` and
`dominantFamily` iterate a Swift `Dictionary`, and Swift seeds its hasher per
process, so the noisy-OR product is multiplied in an order that varies
between launches. Floating-point multiplication is not associative: identical
inputs can differ in the last bits between runs, and a differing last bit
either side of a band cut is a different band. The Rust port takes a slice,
multiplies in slice order, offers `canonical_order` for callers that must
agree bit for bit, and breaks `dominant_family` ties by name instead of by
iteration order. This is recorded rather than fixed in Swift because it is a
change to shipping app behaviour and belongs to its own pass.

### Still split, deliberately

The app runs the Swift copy of these equations; the Rust port serves the
trainers and is the reference implementation. They cannot share code without
a boundary, and there is none — see the section above for why. Bringing them
under one implementation means a bulk boundary through swift-bridge, which is
the same decision the transit engine forces, and it should be made once for
both rather than twice.

## Is Swift only the GUI? An accounting (2026-09-09)

The stated architecture is Rust for compute, Swift for the UI. Measured
against the 39,766 lines of Swift in the app, it is not what shipped:

| role | lines | share |
|---|---:|---:|
| UI (SwiftUI views, theme, intents, CarPlay) | 11,376 | 29% |
| App model (`FLOWSApp.swift`) | 4,708 | 12% |
| Platform glue (audio, speech, music, Bluetooth, watch, keychain, MapKit routing/search, location) | 8,249 | 21% |
| Feed ingestion and parsing (NWS, WMO, live hazard feeds, EPA, fuel, radio) | 5,941 | 15% |
| **Pure compute and models — no platform dependency** | **9,492** | **24%** |

The last row is the expansion. It is 49 files that import
nothing beyond Foundation (or CoreLocation for the coordinate struct alone)
and compute something: risk equations, learned models, a trainer, policies,
rankings, tables. Add the roughly 803 lines of
route-scoring functions inside the app model (`scored`, `attributeScored`,
`hydrateRouteRisk`, `learnedETA`, the grade and corridor updaters) and about
a quarter of the Swift in the app is compute that the architecture says
belongs in Rust.

The platform-glue and feed rows are Swift by necessity: the frameworks are
Apple's, and network I/O is fine in Swift. What is *not* fine is that the
parsing inside the feed row — the third-party bytes the standard's §6.4 calls
the natural fuzz targets — is also Swift.

### The one Swift↔Rust interface that exists, and it passes

There is no call boundary. The interface today is three binary artifacts
Rust writes and Swift reads, and each Swift reader validates the way §3.20
and §3.25.1 require before trusting a byte:

| artifact | writer | Swift reader | validates |
|---|---|---|---|
| `.fps` place shards (`FPS1`) | `places-shard` | `PlacesStore` | magic, version, record and cell counts, grid offset, FNV-1a body hash |
| `history_harmonic.bin` (`FLHH`) | `history-baseline` | `HarmonicClimatology` | magic, version, per-section bounds, exact total length |
| risk bundle (`FRB1`) | `bundle-frb` | `RiskFieldService` | magic, family and ZIP counts, FNV-1a body hash, bounds guard per section |

The `.ftt` transit tables (`FTT1`) have a Rust reader and no Swift reader
yet; the transit engine is not live.

### Migration order, if Swift is to be the GUI

Ordered by how much of the app's *answer* each one decides, and by whether
a Rust twin already exists:

1. **Risk equations** — `RiskEquations.swift` (476 lines). The Rust port exists
   (`flows-core::families`, `::scoring`) and the two are pinned bit-for-bit.
   This is the first crossing for swift-bridge, and it retires a duplicate.
2. **Route scoring in the app model** — `scored`, `attributeScored`,
   `hydrateRouteRisk`, `sampleRealizedRisk` (~450 lines). Runs per sample
   per route on the main actor; it is the leading candidate for the Mac
   planning stall as well as the clearest "compute in the UI layer".
3. **The learned models** — `SeasonalRiskModel` (672), `TrafficLearning`
   (279), `RoadEfficiencyLearning` (202), `EverydayRadius`
   (520), and `RouteHeadTrainer` (149) — an on-device *trainer*
   in the UI language, whose offline twin is `flows-train`.
4. **The field and climatology readers** — `RiskFieldService` (492),
   `HarmonicClimatology` (171), `LatitudeBands`, `ClimateProfiles`: they
   read Rust-written bytes and would be simpler as Rust returning values.
5. **Policies and tables** — `CrashLogic`, `EscalationPolicy`,
   `ShelterPolicy`, `SpeedLaw`, `TowingLimits`, `FilterLimits`,
   `DriveEfficiency`, `POIRanking`, `BadgeClustering`: pure, already pinned
   by tests, mechanical to move.
6. **Parsers of third-party bytes** — `ScannerIncidents`,
   `AlertEntityParser`, and the JSON feature parsing inside the feed files:
   the fuzz targets, which the standard wants in safe Rust with property
   tests.

Each step crosses the swift-bridge boundary verified earlier in this
document. Step 1 is sized at one bridge module, a `build.rs`, the generated
Swift and header added to the Xcode project, and the three cross-compiled
slices restored to `project.yml`.

## The transition, step 1: the bridge, the risk equations, the decoder (2026-09-14)

### A correction first

Earlier sections of this document say swift-bridge "exports via
`#[export_name]` … which is precisely why it survives `forbid`", and a
measurement quoted "0 unsafe" in its expansion. Both are wrong. That "0" came
from a command that silently printed nothing. Expanding the macro on stable
(`RUSTC_BOOTSTRAP=1 cargo rustc -- -Zunpretty=expanded`) shows **10 `unsafe`
blocks and 15 `#[export_name]` `extern "C"` functions**. `forbid(unsafe_code)`
stays silent because rustc does not apply that lint to output from an
*external* proc macro. A control proves the lint is live: a local
`macro_rules!` emitting `unsafe` in the same crate is rejected.

So the accurate statement is:
- project-authored Rust contains **no `unsafe`**, and every crate forbids it;
- the raw-pointer glue exists, generated by the pinned provider, and it is
  the provider's trusted computing base (§3.15 step 5, §3.23, §3.25.5);
- that glue lives in `flows-bridge` only, and `flows-core` has no swift-bridge
  dependency.

### Shape

| layer | holds | rules |
|---|---|---|
| `rust/flows-core` | every equation, table and decoder | zero dependencies, `forbid(unsafe_code)`, does not know Swift exists |
| `rust/flows-bridge` | swift-bridge declarations plus thin forwarders | `forbid(unsafe_code)`; every export runs through `contain` (a panic becomes a documented fallback, never an abort mid-drive); lengths validated first |
| `apple/FLOWS/RustBridge` | generated Swift and C, plus an authored bridging header | committed, never hand-edited; `build.rs` rewrites a file only when its bytes change; CI fails on drift |
| Swift facades (`RiskEquations`, `FlowsCore`) | the same Swift API as before, no arithmetic | tables read from Rust once (`RustTables`); no Swift copy of a weight, cut or family list |

**Xcode.** The iOS, macOS and test targets depend on a `RustBridge`
aggregate target that runs `scripts/build_rust_bridge.sh`.
- Script sandboxing is off on that one target: cargo writes incremental state
  throughout `rust/target`. An external-build target was tried first and
  fails under the project's sandboxing.
- **The script builds every platform library on every run, and reads nothing
  from Xcode about which one is wanted.** The aggregate target is built with
  the macOS SDK even when an iOS app depends on it (`PLATFORM_NAME=macosx`
  during an iOS simulator build), and its `$ARCHS` said arm64 while the app
  built arm64 and x86_64. The first version trusted `PLATFORM_NAME`, linked
  nothing into iOS, and the gate refused to commit it. Cargo does no work
  for an up-to-date target.
- It runs cargo in a clean environment, because Xcode's `SDKROOT` breaks
  host-side build scripts.
- A missing cargo is a hard error. Silently linking a stale library is how
  the app would ship old Rust.

**Encodings across the line.**
- The per-sample combine gets dense slots, one per family Rust knows, with NaN
  for absent. The dictionary's iteration order cannot reach the product, and
  no strings cross on the hot path.
- A dictionary with arbitrary keys crosses as the keys joined by U+001F plus
  a parallel `f64` buffer. The answer is a position, so no string crosses
  back.
- An optional `f64` is a value plus a `has_` flag.

### Two rules swift-bridge 0.1.59 imposes on every caller

Read from its own source:
1. **Never pass an empty buffer.** `FfiSlice::as_slice` calls
   `slice::from_raw_parts` without a null check, and Swift passes an empty
   array's buffer with a nil base address. That is undefined behaviour in
   Rust even at length zero. Every facade returns the empty answer before
   crossing.
2. **A `&str` must be valid UTF-8.** `RustStr::to_str` panics otherwise,
   inside generated code, before containment can catch it. Pass a Swift
   `String`, which is always valid UTF-8, never raw bytes.

### Fidelity: a frozen oracle, not a port-and-hope

Before any Swift was replaced, the original Swift risk code (commit
`17f6436`) was compiled into a harness. The harness recorded **7,381
input→output records** as IEEE bit patterns, covering NaN, ±0, ±∞, every band
edge, exact ties, adversarial strings and random polylines. Three runs were
byte-identical. The one harness nondeterminism, tie injection through
`Dictionary.keys.first`, was found and removed. The fixture lives in
`rust/flows-bridge/tests/fixtures/` and is never regenerated from Rust.

Rust reproduces **7,380 of 7,381 bit for bit**. Getting there took two
deliberate choices:
- **Swift's `min`/`max`, not IEEE's.** Swift's `max(x, y)` is
  `y >= x ? y : x`, so a NaN operand propagates and signed-zero ties are
  ordered. `f64::max` discards NaN. `flows-core::fcmp` reproduces the app.
- **No R-era guard on non-finite thresholds.** The R original returned 0; the
  app propagates NaN, which bands Clear. The app's behaviour is what drivers
  have had, and every R-computed in-domain vector still passes. *A NaN reaching
  a route average would poison it; that is shipping behaviour worth a separate
  decision, not a silent change during a port.*

The one divergence is allow-listed, and the allow-list fails if it ever stops
diverging. Swift's `String.contains` matches whole grapheme clusters, so
`"storm\u{301}"` does not contain `"storm"`, while Rust matches bytes. Exact
parity needs Unicode grapheme tables, and no real alert event name puts a
combining mark on an English keyword. The family it yields is a capped
predictor.

A second, independent check links the real bridge into a Swift binary. The
same seeded inputs, fed through the old Swift build and the new bridged
build, produce **identical checksums over every output bit**.

### Cost of the crossing, measured

Best of 7, `-O -wmo`, the same seeded inputs through both builds:

| call | Swift | Rust via bridge |
|---|---:|---:|
| realized risk, per corridor sample (8–9 families) | 3,496 ns | 1,778 ns |
| risk band | 10.0 ns | 11.4 ns |
| naming an area's hazard (8–9 families) | 621 ns | 4,024 ns |
| decode a 10 KB polyline | 39.8 µs | 37.8 µs |

The per-sample combine, the hot path, got twice as fast. Naming an area got
6.5× slower, because arbitrary keys must be joined and copied across. It runs
once per grid point of the viewport sweep, at most 49 per camera-settle,
inside a task group next to about eleven network fetches: at most 0.2 ms.
Not material, so not optimized (§1.6, §4.8).

## The transition: plan of record (2026-09-14)

### Scope, measured

Eleven agents classified every Swift file in the app by mechanism, against a
written rubric (see the classification rubric in the session record).

| | files |
|---|---:|
| stay: GUI (views, styling, copy, map drawing, symbol choice) | 13 |
| stay: platform (Apple frameworks, networking, persistence) | 17 |
| carry compute to move | 82 |

They hold **365 items** to move, about **9,300 estimated lines of Rust**:

| tier | items |
|---|---:|
| 1 — risk and route answer | 50 |
| 2 — learned-model math | 30 |
| 3 — policy and decisions | 159 |
| 4 — parsers of third-party text and bytes | 51 |
| 5 — other domain math | 75 |

### Order

Dependencies decide it. Nothing moves before what it calls.

1. **Wave 1: foundations and leaves.**
   - Geo kernel: the equirectangular `meters` behind about 90 call sites,
     bearing, point-to-segment, ±180° wraps, first-minimum nearest searches,
     grid keys. Pinned by oracle as Rust twins. The Swift `meters` is
     switched only when its compute callers have moved, so no loop pays a
     per-call crossing in the meantime.
   - Climate and astronomy: ClimateProfiles, LatitudeBands, DaylightClock,
     the FLHH reader, RiskTiming.
   - Alert text and safety policy: ImminentAlerts with `bandInput`,
     AlertEntityParser, ScannerIncidents, ShelterPolicy, EscalationPolicy, and
     the event interpretation in HazardStyle.
   - Vehicle and trip policy: SpeedLaw, SpeedSign, TowingLimits,
     FilterLimits, GradeProfile, TripCosts, TripNeeds, DriveEfficiency, the
     CrashLogic decisions, PursuitReach, VehicleSpecs and VehicleProfile math,
     the EPA class specs.
   - Brand, price and tag text: BrandKnowledge, the RatingsAndCost policy,
     FuelPrices, LaneData, EnforcementCameras tags.
   - Learned-model math, with state kept in Swift: SeasonalRiskModel with
     RouteHeadTrainer; EverydayRadius, TrafficLearning,
     RoadEfficiencyLearning, Buffer/Refuel learning, DrivingProfile,
     DestinationPrediction.
2. **Wave 2: readers, feeds, places.**
   - RiskFieldService as an opaque FRB1 reader, plus the NWS forecast
     predictors.
   - The interpretation inside LiveHazardFeeds, WeatherAlertService and
     PrimarySources.
   - POIRanking, PlacesStore (an opaque FPS1 reader) and the POIService
     decisions.
   - OfflineCorridors, Amtrak, radio tuning, recent-destination merge,
     breadcrumbs, FuelWarning, HybridWalk, AirTravel, transit estimates,
     Mobility, AdaptiveTuning, SignalQuality, playback decisions, spoken-reply
     parsing, TripShare, VehicleLink, RouteAttributes.
3. **Wave 3: the route and the app model.**
   - RouteService and NavigationEngine over one opaque per-leg geometry.
   - AppModel's route scoring as **one batched call off the main actor**
     (today the blend loop runs per sample on the main actor).
   - Live corridor updates and learned ETA.
   - The compute leaked into views: the ContentView sweep, RouteChoicesView's
     route designations, NavigationHUD.
   - Last, the geo facade itself.

### Rules every port follows

1. **Oracle first.** Compile the original Swift at the base commit into a
   harness, record bit patterns, and commit the harness and fixture. The
   Rust must match bit for bit. Any divergence is allow-listed with a reason
   and self-checking. The harness is reproducible: seeded inputs, never
   iterate a Dictionary, three identical runs.
2. **Swift semantics, exactly.** Use `fcmp` for min/max. Sorts must be
   stable. Folds are sequential, in index order. First-minimum ties are
   kept. Signed index arithmetic uses checked or `isize` operations, never a
   `usize` that underflows.
3. **Behaviour is preserved.** Duplicated Swift rules that disagree are
   ported as they are and reported. A port never unifies them; that is a
   behaviour change for the owner to decide.
4. **Persisted layouts do not change.** Swift keeps every Codable type,
   sealing and UserDefaults key. Rust receives values.
5. **Bridge rules.**
   - Never pass an empty buffer.
   - Pass a Swift `String` for every `&str`.
   - Batch per §3.25.5.
   - Names are `flows_<module>_…`.
   - The dense and joined encodings above.
6. **Swift keeps its API.** Facades live in the existing files, and no new
   Swift source files are added, because the test target lists sources
   explicitly. New Swift tests go in new files under `FLOWSTests/`.
7. **Gate per wave.**
   - Each agent runs cargo fmt, clippy, the tests and
     `scripts/typecheck_swift_app.sh`.
   - At integration: the FLOWSTests suite, the four-build Release matrix,
     lipo checks, and old-versus-new benchmarks for any hot path.

### Findings kept out of the port: behaviour changes for the owner

- A non-finite threshold propagates NaN, which bands Clear. A NaN reaching a
  route average would poison it.
- There are two band-input builders with different key sources: the
  ContentView sweep, and `RiskEquations.bandInput` used by route scoring.
- Alert event names are classified three ways with different tables:
  HazardStyle, `RiskEquations.alertFamily` and ShelterPolicy.
- Route "safest" and "fastest" designations are computed in several places
  with different gates.
- State bounding boxes are iterated in per-launch hash order
  (LiveHazardFeeds.swift:1431, WeatherAlertService.swift:285). This is the
  same class of defect as the risk-combine one.
- The places-shard format (FPS1) disagrees between the Rust writer and
  reader and the Swift reader on four points: 32-byte files, grid-key
  ordering, invalid UTF-8 (reject versus lossy), and eager versus lazy
  decode. The Rust reader also lacks the record-count allocation bound.
  (Since the fourth wave-2 landing the app reads shards with
  `flows_core::places::PlacesIndex`, a faithful port of the Swift reader;
  the `flows-train` reader still differs on those four points.)
- A warning of the same threat rank never replaces a showing imminent
  banner, even when it needs shelter and the banner does not (the guard in
  `FLOWSApp.swift` compares ranks only). This is the owner's ded56c1 rule;
  the facade review flagged it as the one place a Red shelter-level warning
  ahead is not announced.
- The shower brand pick's comment says anchored matches stopped "Vista
  Travel" reading as TA, but `"ta travel"` still matches inside it. The
  port keeps the answer the code gave.
- **Environment:** the Apple Development identity that signed the last Mac
  install is no longer in the keychain. Signed Mac builds and the reinstall
  wait on restoring it.

## Audit, 2026-09-15: what the code says about itself

Method: compiler gates (clippy default and pedantic, the Swift compiler for
every target, a Swift 6 strict-concurrency preview), pattern scans for
crash-capable, blocking, quadratic and order-dependent code, then reading
every hit by hand. No agents.

### Fixed (commit "Audit fixes")

CI target gap; unbounded `with_capacity` from a shard header; a NaN-capable
float sort; a main-actor table read from tests; an unreachable duplicate in
the hazard classifier. Details in that commit.

### Cleared: suspicions that turned out not to be defects

- `roadClosures` picks at most three uncached feeds per sweep. The registry
  is an array in fetch order, not a dictionary, so the choice is the same
  on every launch; feeds beyond the budget are fetched on later sweeps as
  earlier ones become cached.
- `statesContaining` returns codes in dictionary order, but every consumer
  treats the list as a set and the alert union is built over sorted state
  codes, so no answer depends on that order.
- Every `unwrap` in the transit and shard parsers is invariant-backed: a
  trip with a missing first or last time is dropped before the fill loop,
  the `.ftt` header is length-checked before the fixed slices, and each
  length-prefixed read is bounds-checked by `take`.
- The 16 direct indexes in the hazard-feed parser are each behind a count
  guard on the same or the preceding line.
- The per-sample feed scans (gauges, water, closures) are linear in the
  points, but every feed is capped at 200 points, so a route of a few
  hundred samples costs well under a millisecond there. Not the stall.
- The shard writer emits the grid index in ascending key order; the Swift
  reader's binary search is valid. The Rust reader rejects invalid UTF-8
  where the Swift reader is lossy; the writer never emits any, so no file
  can tell them apart.

### Decided by the owner on 2026-09-15, and done

1. **Routes see the live-feed primaries.** `LiveHazardScoring.swift` fetches
   one clipped snapshot per area and scores it with the exact expressions
   the map sweep used; the sweep now calls the same function, and the route
   folds the result into the same two-tier band input. A route through a
   wildfire is Red with no NWS alert, as the map beside it always was.
2. **A dust storm is both hazards.** Its own kind, drawn for Dust Storm and
   Blowing Dust Warnings; the band keeps it a realized storm; the advice
   covers the road you cannot see and the air you should not breathe.
3. **One classifier, and life first.** `flows-core::alerts` holds the display
   table, the shelter tables, the life-safety and lookout lists, the action
   rule and a threat rank; the three Swift files call it. Pinned to what the
   Swift tables said by a 185-event oracle, with three deliberate changes
   allow-listed: a Red Flag Warning (fire weather, a predictor) no longer
   commands "shelter now"; a Tornado Emergency is life-safety; and the
   combining-mark byte/grapheme edge is named. Imminent alerts are chosen by
   rank, then CAP severity, then distance, and a showing warning is replaced
   only by a higher-ranked one, so a flood advisory cannot displace a
   tornado and a lookout displaces nothing.
4. Safest and fastest are still computed in two places each by the same
   rule. Not wrong; a rule change would have to be made twice.
5. `PlannedRoute` is not `Sendable`; Swift 6 migration item.

### Not defects, noted

- Pedantic clippy: "identical match arms" in the GTFS route-type and RAPTOR
  parent matches are separate arms with separate comments by intent; the
  float `while` loop is in a test; the "overflowing midpoint" is on latitudes.
- Six wave-1 worktrees under `.claude/worktrees/wf_10090775-85a-*` hold
  uncommitted partial work from the run that died with the last session,
  including a geo oracle fixture and harness. They are left in place to be
  resumed, not deleted.

## Wave 1, first landing: the geo kernel and the trip/vehicle twins (2026-09-15)

The parallel wave-1 run died with its session before any commit. Its
worktrees were assessed by hand; two groups were sound enough to land.

**Geo** (`flows-core::geo`, 5,322-record oracle: every record exact except nine bearings, whose largest lateral gap at the target is 0.16 µm, and sixteen cone-edge yes/no answers checked by recomputing the edge distance). The equirectangular
`meters` behind about 90 call sites, bearings, the ahead cone, point-to-segment
distance, the longitude wraps, every first-minimum nearest search with its
tie rule, and the three grid keys. No Swift call site is switched yet: a
crossing inside ninety call sites, many in loops that move later, would pay
per call for nothing. The twins wait for their callers.

**Trip and vehicle** (`flows-core::trip_vehicle`, 8,704-record oracle, bit-exact;
`flows-bridge::trip_vehicle`, 58 functions and three shared structs). Trip
costs and needs, the crash-detection decisions, the vehicle spec table and
profile math, EPA class specs. The bridge landed one step ahead of its Swift
callers; the facade switch for `TripCosts`, `TripNeeds`, `CrashLogic`,
`VehicleSpecs`, `VehicleProfile` and `EPAVehicleDatabase` followed the same
day (see "the trip and vehicle facades switch" below). The nine `!(a > b)`
tests the port used for NaN parity are written as `a <= b || a.is_nan()`:
the same predicate, with the NaN case visible.

### Trigonometry is bit-portable only as far as the compiler leaves it alone

The geo oracle failed on 25 of 5,322 records: nine bearings one unit in the
last place off, and twelve ahead-cone answers that flipped because those
bearings sat on the cone's edge. Every other intermediate matched. The cause
was found by experiment, not reasoning: when one function evaluates both
`sin(x)` and `cos(x)`, the Apple backend may fuse the pair into
`__sincos_stret`, whose sine differs from the standalone `sin` by one ulp for
some arguments. Whether it fuses depends on the compiler, the optimisation
level and the shape of the surrounding code. The Swift *Release* build of
the app fuses inside its bearing formula — so the oracle, and the shipping
app, carry the fused sine — while a Swift Debug build does not. The original
is not consistent with itself across build configurations.

That is not a contract Rust can reproduce, and it should not try. The kernel
routes every trig call through its own `#[inline(never)]` wrapper so no
function contains the pair; the Rust value is then the standalone sine in
every build, identical in debug and release. The oracle pins the honest
contract in physical terms: a bearing may point away from the app's by at
most one micrometre of lateral displacement at the target (the sine's one
ulp is amplified through `atan2` in proportion to how close the two points
are, so a degree-valued tolerance is wrong at one separation or another),
and a yes/no answer derived from a bearing — the ahead cone, fuel-station
reachability — may differ only when the bearing lies within a nanodegree of
the cone's edge, checked by recomputing that distance rather than by a
list. Nine bearings and sixteen edge answers fall under those rules; the
largest observed lateral gap is 0.16 µm. An `extern "C"` sincos would have matched the
Release app and broken with its Debug build, and is forbidden anyway (§3.15).

## Wave 1, second landing: the seasonal model (2026-09-15)

`flows-core::seasonal` (1,247 lines, 11 unit tests) now carries every number
and every decision of `SeasonalRiskModel` and `RouteHeadTrainer`: the
decaying week accumulator and its frequency gate; the seasonal prior and the
calibration RMSE; the route, hub, edge and origin keys; the origin update
with both eviction orders; the learned and the legacy home; the frozen
eight-feature route vector; the MLP forward pass; the anchored fine-tune and
its mean squared error; the head choice, the tune gates and the ranking
blend. State and persistence — the sealed Codable stores, the Calendar —
stay in Swift, as the plan of record says.

The dead worktree left the core and a 3,163-record fixture but no oracle
test. The test (`swift_seasonal_oracle.rs`, 29 record kinds) was written by
hand from the harness's record layouts and passes bit for bit in debug and
release. Twenty-one kinds call one Rust function each. The other eight
exercise Swift *store methods* — `record`, `recordOrigin`, `recordEdges`,
`learnedHome`, `trainingRows`, the two evictions — which Rust exposes as
pure pieces; the test recomposes them the way the Swift did, over the
snapshot each record carries. The harness chose inputs whose answers do not
depend on Dictionary order (no weight ties at a cut, distinct per-cell
totals), so the sorted order the test folds in is as good as Swift's, and
the cases where the original's answer *would* depend on order are left out
of the fixture and named in the harness as findings.

The harness was rebuilt from the base commit to check the recipe: four runs
(three plain, one `SWIFT_DETERMINISTIC_HASHING=1`) are byte-identical to the
fixture body. Its binary imports `__sincos_stret` — the route feature vector
takes sin and cos of one angle — and every record still matched: the fused
sine differs from the standalone only for some arguments, and the fixture's
angles are not among them. `route_features` is left as written; the oracle
in both build modes is what pins it, not a wrapper.

Where Swift trapped (integer overflow, `Int(Double)` out of range, a
negative epoch count, a hidden row shorter than the input) the Rust returns
a documented value — saturation or `None`. Those inputs crashed the app, so
the fixture, being the app's output, cannot contain them. Five `!(a > b)`
guards were rewritten as `a <= b || a.is_nan()` for the same reason as in
trip_vehicle, and one as `partial_cmp`.

The bridge module stays the reserved stub. The two Swift classes switch to
it when their group's callers move, as geo's do.

## Wave 1, third landing: the learned models (2026-09-15)

`flows-core::learning` (1,371 lines, 17 unit tests) carries the everyday
radius, the traffic-delay and road-efficiency models, buffer and refuel
learning, the personal ETA correction and destination prediction: every
update, gate, eviction and prediction of `EverydayRadius`,
`TrafficLearning`, `RoadEfficiencyLearning`, `BufferLearning`,
`RefuelLearning`, `DrivingProfile` and `DestinationPrediction`. State stays
in Swift. It also carries Swift's own sort, step for step, because two of the
rankings sort with comparators that a NaN makes inconsistent, and only the
same sequence of comparisons reproduces the order the app produced.

The dead worktree left the core and a harness but no fixture. The harness
was compiled from the base commit (it needs the two seasonal sources, since
`EverydayPlaces` names `SeasonalRiskModel.shared`, and the same two stubs)
and run four times, byte-identical: 10,673 records in 37 kinds. The oracle
test, written by hand from the record layouts, passes bit for bit in debug
and in release, with two records named as divergences (below).

### The optimiser is part of the original, again: `pow(0.5, x)`

The first run failed nine decay records, all at the harness's decay
threshold (a factor of 0.999 decides whether a store decays at all), and
only in the debug build. Measured over 26,006 arguments: Swift's Release
build and Rust's release build both compile `pow(0.5, x)` as `exp2(-x)` —
LLVM rewrites any power-of-two base — and agree with each other everywhere;
Swift's Debug build, Rust's debug build, and `pow` with a base the compiler
cannot see all call libm `pow`, which differs from `exp2` by one ulp on
0.4 % of arguments. The harness had bisected to the threshold, so it sat on
one. The fixture, and the shipping app, carry the `exp2` value.

Both learned-model modules now write the decay as `(t / -half_life).exp2()`.
The sign sits on the divisor, not the quotient: a negated NaN carries a
flipped sign bit, which the optimiser folds into the constant and a debug
build does not, and five further records — all NaN scores — showed exactly
that. Every build now agrees with the app. The seasonal module had the same
`0.5.powf` expression and passed both ways only because none of its 3,163
records landed on a disagreeing argument; it is rewritten the same way and
still passes.

### Two records where the port differs by design

Swift's `String <` is not a consistent order for canonically equivalent
names in different encodings: for "öz" and "o\u{308}" it answers false in
both directions, and it places "가 " before the jamo spelling of "가" though
the precomposed prefix is shorter. The harness put those cases in on
purpose. The port orders NFC bytes (the Swift facade normalises names
first), which is Swift's own order once both names are NFC. The test names
the two records and fails if they stop diverging.

The bridge module stays the reserved stub; the seven Swift classes switch
to it together with their callers.

## Wave 1, fourth landing: vehicle policy (2026-09-15)

`flows-core::vehicle_policy` (1,455 lines, 20 unit tests) carries the speed
bar's legal lines and limit estimate (`SpeedLaw`), the compass table, the
posted-limit parser and judgment (`SpeedSign`), the pursuit reach circle,
the towing class estimates and violation check (`TowingLimits`), the route
filter's three admission rules and the grade slider's default
(`FilterLimits`), the grade table (`GradeProfile`) and every penalty and
verdict of `DriveEfficiency`. `flows-bridge::vehicle_policy` exposes 48
functions. Five Swift files are facades now — `SpeedLaw`, `SpeedSign`,
`TowingLimits`, `FilterLimits`, `PursuitReach` hold no copy of a threshold,
table or rule; the two constants the UI reads come from Rust. `GradeProfile`
and `DriveEfficiency` keep their Swift until their callers move; the bridge
is ready for them.

The dead worktree left the core four constants short of compiling, plus a
bridge, a test, a harness and the facade edits, but no fixture. The four
constants are Unicode tables — the scalars for which Swift's
`Character.isNumber` holds, those that join a preceding ASCII character or a
following one into a single grapheme cluster, and Foundation's
`whitespaces` — which the parser needs because `SpeedSign.parseMaxspeed`
reads the tag through Swift's `String`, that is, by grapheme cluster and not
by scalar. The harness reads those properties from the Swift runtime over
every scalar and writes them as ranges; the Rust tables were generated from
that output, never typed, and the test checks each table over the whole
scalar domain before it parses a single tag. The harness was rebuilt from
the base commit and run four times, byte-identical: 14,260 records in 35
kinds. The oracle passes bit for bit in debug and in release.

### Which NaN comes out of a product is the compiler's choice

Two records failed at first, both `PursuitReach.radiusMeters` with a NaN in
both arguments (one negative, one carrying a payload). IEEE 754 does not say
which operand's NaN a product returns; Apple silicon returns the first
operand's. The Swift Release build had emitted the multiplication with the
speed first and the elapsed time second — the reverse of the source — so the
speed's canonical NaN came out. The Rust writes the product in that order,
with a comment saying why, and matches in both build modes. A NaN's sign
and payload never reach a driver; the oracle compares bits, so the port
states exactly what it does.

## Wave 1, fifth landing: climate and astronomy (2026-09-15)

`flows-core::climate` was written by hand from the five Swift files — the
dead worktree left only a harness — and carries the latitude bands, the
twelve climate types with their seasonal norms and gates, the NOAA
solar-position terms, twilight, night, the sun's height and the next change,
the FLHH harmonic-climatology reader with its week trig and scores, and risk
timing. Instants are Foundation's own double (seconds since the reference
date), so a Swift facade passes `timeIntervalSinceReferenceDate` through.
The trigonometry goes through a new shared module, `fmath`, one libm call per
function, which the geo kernel now uses too (its oracle still passes both
ways); `Int(Double)` lives once in `fcmp` for new code, the three earlier
copies to be folded in.

The harness is the dead run's, corrected: its probe of
`arrivalOffsets(sampleCount: Int.max)` did not trap the Swift — Swift began
allocating the array and the process grew until the owner's machine ran out
of memory (the "memory leak" reported mid-session was this harness, not the
app). The probe is gone, the finding is recorded, and the port refuses counts
above 2^20. The three random sweeps over the daylight functions were digests
of 20,000 values each; a digest cannot tolerate the one-ulp sine the Release
compiler's `sincos` fusion produces, so they are written out sample by sample
(2,000 each) and compared to a stated physical tolerance. Everything else —
including the 212,550-value day digest, the 52 weekly angles and the
1.9-million-score big table — matched bit for bit; five values in 13,447
needed the tolerance, the largest by 6e-14, and every dawn, dusk and
next-change instant is exact.

Two facts about Foundation, learned from the fixture: `String(bytes:encoding:)`
drops one leading byte-order mark (mirrored); `Date`'s `<=` and `>=` are
Comparable's `!(rhs < lhs)`, so they hold for a NaN (mirrored where the code
compares instants). And one divergence by design: Swift's `String` equality is
canonical equivalence, the port's is bytes; on the harness's two odd-UTF-8
tables exactly 287 records differ, every one on a non-ASCII key or query, and
the test pins that count. The FLHH writer emits ASCII only.

The bridge module stays the reserved stub; the five Swift files switch with
their callers.

## Wave 1: the trip and vehicle facades switch (2026-09-15)

The trip/vehicle bridge landed a step ahead of its callers; the six Swift
files now call it. `TripCosts`, `TripNeeds`, `CrashLogic` with `HOSRules`,
`VehicleSpecs`, `VehicleProfile` with `VehicleStore`, and `EPAClassSpecs`
hold no threshold, factor, table row or formula: the curated vehicle table
(three parallel lists, ten numbers a row) is read from Rust once at first
use, the crash and hours-of-service decisions cross with their windows, the
range model crosses a nil city/highway split as a value plus a flag, and the
schedule comes back as `[mile, code, …]` pairs decoded by the one place Swift
spells the bridge's fuel and need codes (an extension in `TripCosts.swift`,
which `TowingLimits` now uses too). What stays is presentation and state:
`Need.symbol`, the emergency message and its formatter, the check-in
cadence, `displayName`, the persisted profile and the store's `UserDefaults`.
Two guards keep swift-bridge's rule that an empty buffer never crosses: an
empty impact window is no impact, and an empty schedule has no next stop —
both the Swift's own answers.

## Wave 1: the climate facades switch (2026-09-15)

`flows-bridge::climate` exposes the climate core (36 functions and one opaque
type), and the five Swift files call it. `LatitudeBands`, `ClimateProfiles`,
`DaylightClock`, `RiskTiming` and `HarmonicClimatology` hold no anchor,
envelope, seasonal table, orbital term or coefficient: instants cross as
`timeIntervalSinceReferenceDate`; an optional elevation as a value plus a
flag; a climate type as its code. The harmonic table is the first opaque
Rust type across the bridge — Swift's `HarmonicClimatology` is a handle to a
table parsed once in Rust and never copied out, so the 33,613-ZIP rescore
scores through the handle with the week's trig factors hoisted as before.
What stays is presentation and state: the climate-type labels, the
`precise` per-ZIP snapshot and its cell arithmetic, and the file loading.

Two answers the Swift never gave: a latitude that is not a number crashed
the Swift's band index; the facade answers the Wisconsin anchor row (band 1)
and says so. A row or family past the harmonic table crashed the Swift's
score; the facade answers NaN. Both are documented at the facade, neither
reaches a driver from the app's own callers.

## Wave 1: the learned-model facades switch (2026-09-15)

`flows-bridge::learning` exposes the learned-model core (72 functions), and
the seven Swift files call it: `EverydayRadius`, `TrafficLearning`,
`RoadEfficiencyLearning`, `BufferLearning`, `RefuelLearning`,
`DrivingProfile` and `DestinationPrediction` hold no threshold, weight,
half-life, fold or ranking rule. The stores stay Swift — the dictionaries,
the keys, the persistence — and recompose the pure pieces the way the
oracle does: a decay is a plan the store applies to its own cells; a fold
answers the updated cell, or "dropped" where the Swift would have crashed
on a count at `Int.max`; names for the everyday ranking cross in NFC joined
by U+001F; destinations come back as `[index, score, reason code]` triples
with the words kept in Swift. Empty lists never cross: each facade answers
the empty case itself (no trips: the default radius; no places: nothing to
rank; no answers: accuracy 0), which is the Swift's own answer in each case.

One answer the Swift never gave: a router estimate that is not a number made
`predictedDelayMinutes` crash; the facade reports no delay.

## Wave 1: the seasonal model's facades switch (2026-09-15)

`flows-bridge::seasonal` exposes the seasonal core (53 functions), and
`SeasonalRiskModel.swift` with `RouteHeadTrainer.swift` call it. The store
keeps its dictionaries, its persistence and its calendar, and recomposes the
pure pieces the way the oracle does: a week cell decays and folds through
the bridge; the prior takes its three week cells with presence flags; both
evictions take the store's own iteration order and answer positions; the
learned home takes seven numbers an entry; training rows take eleven a cell
and come back eight a row. The learned head crosses flat — hidden count,
biases, output weights, row widths, rows — with the input in front of it
for a prediction, so a head with no hidden units and an empty input still
cross as one non-empty buffer; the fine-tune answers the tuned head the same
way with the sample count in front, or nothing. Training rows cross as
sixteen numbers each, a value and a presence flag per column, because a
present NaN and an absent column mean different things to the Swift they
replace. The frozen 8-feature vector, the week of year, the head choice,
the tune gates and the ranking blend are bridge calls; the private
haversine is gone with them.

One answer the Swift never gave: a coordinate that is not a number crashed
the route and edge keys; the facades answer cell 0.

With this, every wave-1 core that has landed is in use by the app: risk,
alerts, vehicle policy (five of seven files), trip and vehicle, climate,
the learned models and the seasonal model. Geo waits for its compute
callers by design.

## Wave 1: the last two vehicle-policy facades switch (2026-09-15)

`GradeProfile` and `DriveEfficiency` now call `flows-bridge::vehicle_policy`,
which had carried their math since the fourth landing. Grade segments cross
as flat (start, end, grade) triples and a missing elevation as a value plus a
presence byte; every drive-efficiency penalty, the headwind, the airspeed,
the drag sensitivity, the load factor, the score and the verdict cross with
their optionals as a value plus a flag. All seven files of the group are
facades now. `GradeSegment.gradeDegrees` (an arctangent for display) stays,
with `FilterLimits.degreesToPercent`'s inverse already in Rust.

## Wave 1: the three small leftovers (2026-09-15)

Three pieces of arithmetic the facade landings had left in Swift are in Rust,
each pinned by new frozen-oracle records. The three harnesses grew a section
at their end, each with its own seeded generator so no earlier draw moved;
regenerated from the base commit, four runs byte-identical, every previous
record unchanged, every new record matched bit for bit:

- `EverydayStore.miles`, the haversine, is `learning::everyday_miles`
  (610 `miles` records). It is written in the Swift's operation order —
  each sine taken once and squared, the products left to right,
  `2 · r · atan2(√s, √(1 − s))` — and needed no tolerance.
- `GradeSegment.gradeDegrees`, the display arctangent, is
  `vehicle_policy::grade_degrees` (194 `gd` records), the inverse of
  `degrees_to_percent`.
- `ClimateProfiles.cell` and the home-ring trim in `loadPrecise` are
  `climate::precise_cell`, `precise_cell_indices` and
  `precise_cell_near_home`, wrapping product and truncating division kept.
  The Swift function is private, so the harness observes it through the
  store: a marker profile loaded at one point and probed at another (`cpc`,
  563 records: are two coordinates one cell?), then a trim around a home
  (`cpt`, 816 records: does an earlier cell survive?). Four `trap` probes pin
  that a coordinate the original could not place crashed it; the facade
  answers no cell for such a coordinate and keeps every cell for such a
  home. The re-add of the just-loaded corridor after a trim is the store's
  own step and stays in Swift.
- The four `swift_int` copies are one, `fcmp::swift_int`; `geo::swift_int`
  is its `Result` form.

`SeasonalStore.totalTrips`, a sum of the routes' trip counts, stays: it is
the store's bookkeeping, like `count`.

## Wave 1, sixth landing: brand, price and tag text (2026-09-15)

The last wave-1 group is in Rust: `BrandKnowledge`, the pure parts of
`RatingsAndCost` (countries, tiers, the shower ladder and tables),
`FuelPrices` with the AAA row parser, `LaneData.parse` and the
`EnforcementCameras` tag reading — `flows_core::places_text`, behind 36
bridge functions and five facades. It was the heaviest because those files
stand on Swift's `String`, and the answer was to give Rust Swift's text
rules rather than approximate them: `flows_core::swift_text`.

**`swift_text`.** Six facts about Swift text decide every answer in the
group, and each is reproduced from tables the harness read out of the Swift
6.4 runtime scalar by scalar (`swift_text/tables.rs`, 5,761 generated lines,
checked over all 1,112,064 scalars by the oracle test):

- a `Character` is an extended grapheme cluster — UAX #29 including the
  Indic-conjunct rule, from the runtime's own classes, which a 17-probe
  vector per scalar tells apart; 2,500 random sequences pin the segmenter;
- `isLetter`/`isNumber` read a cluster's first scalar;
- `lowercased()`/`uppercased()` are the full one-to-many mappings, no
  context (a final sigma stays σ, İ becomes i̇, ß becomes SS);
- `==` and dictionary keys are canonical equivalence (`"café" ==
  "cafe\u{301}"`, `"\u{212A}S" == "KS"`), through NFD with the runtime's
  decompositions and combining classes;
- Foundation's `range(of:)`, `contains`, `components(separatedBy:)` and
  `replacingOccurrences` match whole clusters canonically, so `"$\u{301}"`
  holds no `"$"`; `hasSuffix` compares clusters; `trimmingCharacters` trims
  scalars;
- `Double(String)` is Darwin's `strtod` behind Swift's own checks: hex
  floats (lowercase `x` only) correctly rounded to the subnormals, `nan(…)`
  and `snan(…)` payloads read as hex, octal or decimal and kept to 50 bits
  under Apple's quiet or signaling marker, overflow to infinity and
  underflow to zero, a NUL ending the string, a leading space refusing it.

**The oracle.** 23,594 records in 35 kinds, adversarial on purpose (marks
after `$`, joiners, prepends, flags, conjuncts, fullwidth and Kelvin
letters, NULs, every whitespace, hex and NaN speed tags, the AAA window
probed with multi-scalar clusters); three runs byte-identical; every record
matched on the first run of the test — the tables did the work. The
store's own steps are recomposed in the test the way the Swift did them: the
live AAA cache through the harness's stub transport, the driver's shower
report, the city table's dictionary.

**Facades.** The five files keep their types, their UI words (`symbol`,
`title`, `currencySymbol`, `summary`), their I/O (the AAA fetch and cache,
Yelp and Google, `UserDefaults`, the bundled tables) and their colours, and
call the bridge for every decision. `FuelPrices.stateNameToCode` is built
from the Rust table; `stateFactor` is Rust's alone. `EnforcementCameras.
imminent`, `isAhead`, `bearingDegrees` and `warning` stay for the geo
facade, with `LaneData.summary` (plain words for the HUD).

### Remaining wave-1 groups

| group | state | next |
|---|---|---|
| seasonal | LANDED: core + oracle (3,163 records) + bridge (53 functions) + both facades switched | `SeasonalStore.totalTrips` (a sum of counts) is the store's bookkeeping and stays |
| learning | LANDED: core + oracle (11,283 records) + bridge (73 functions) + seven facades switched | — |
| vehicle_policy | LANDED: core + bridge (49 functions) + oracle (14,454 records) + all seven facades switched | — |
| climate | LANDED: core + oracle (14,830 records) + bridge (38 functions, one opaque table type) + five facades switched | — |
| places_text | LANDED: `swift_text` + core + oracle (23,594 records) + bridge (36 functions) + all five facades switched | `EnforcementCameras.imminent`/`warning` and `LaneData.summary` (UI words) wait for the geo callers |
| alerts | done by hand (`ded56c1`), except `bandInput` | switch `bandInput` with the route-scoring move |

## Wave 2, first landing: the risk field as an opaque reader (2026-09-16)

`RiskFieldService` holds the ZIP-level risk field through one opaque Rust
type. `flows_core::risk_field` reads the FRB1 bundle (every bounds check,
the FNV-1a-64 hash, the no-trailing-bytes rule — a corrupt shard is refused,
never repaired), builds the 0.2° grid, answers the nearest centroid within
the 0.27° cosine-scaled reach with the latitude-widened longitude window,
selects a viewport's ringed entries worst-first with Swift's own sort so ties
and NaN scores keep their order, and rescores the national entries against
the harmonic table for the week. The bridge exposes it as `FlowsRiskField`
(three constructors, sixteen methods); the rescore takes the harmonic
table's own handle, the first time one opaque type reads another across the
bridge.

The oracle is the first to drive a loaded service instance: the harness
writes each shard where `candidatePaths()` looks, lets a fresh
`RiskFieldService` load it and records `scoreRow`, `summary` and `zips(in:)`
— 6,335 records in 9 kinds, three runs byte-identical, every record matched
on the first run of the test.

The facade keeps the class, its published state, the file reads and the JSON
fallback (decoded in Swift, handed across as columns), and builds `ZipEntry`
values from the field on demand. `parseFRB1`, `selectZips`, `buildGrid` and
`harmonicRescore` were the Swift's test seams; the tests now build a
`RiskField` and query it. Two places the Swift trapped answer nothing
instead: a coordinate that is not a number, and an entry whose centroid
cannot be placed (left out of the grid).

## Wave 2, second landing: the forecast predictors, and the bridge-linked harness (2026-09-16)

`ForecastConditions.forecastScore` and `.predictorFamilies` — the point
forecast scored against the location's climate profile, the secondary side
of the realized-risk model — are `flows_core::forecast`, behind two bridge
functions and a names getter. The composition is short; the landing's
weight is in its oracle. At the base commit `RiskEquations` was already a
facade over the Rust equations, so the original could not be compiled
alone: the harness now links `libflows_bridge.a` and compiles the generated
bindings beside the base-commit sources (the original `ClimateProfiles` and
`LatitudeBands`, the `RiskEquations` and `FlowsCore` facades,
`InternationalWeather` and `SpeedLaw` for the names `NWSForecastService`
uses) with stubs for the network, cache, alert and diagnostics types the
oracle never touches. That recipe (`oracle-harness/forecast/README.md`)
serves every remaining group whose original already called the bridge —
most of wave 2.

## Wave 2, third landing: the live feeds' scores and the alert service's rules (2026-09-16)

Everything the live feeds and the alert service *decide* is Rust:
`flows_core::hazard_feeds` holds every `HazardFeedScores` score (fire
hotspots and perimeters, quakes, flood gauges and mapped water, space
weather, volcanoes, avalanche and outlook zones, tropical storms, tsunamis,
closures), the snapshot clip and the per-point assembly the map sweep and
the route share, the alert service's cell key, state and marine boxes, ring
containment, the client-side spatial join, the GeoJSON ring decimation and
the corridor's noisy-OR, coverage and worst-first sort, plus the CRE fuel
files' tag scan. The snapshot crosses once as an opaque `FlowsHazardSnapshot`
built from the fetched feeds and is scored per point in place; `clipped`
answers a new one whose lists the facade reads back, so the Swift struct
keeps its fields and its memberwise construction for the tests and the
viewport sweep.

The oracle (6,670 records, 35 kinds) is bridge-linked from commit f36ee9e
and taught two small things recorded in its README: `Double(Substring)`
fails at an embedded NUL where `Double(String)` stops there, and a harness
should sort by bytes, not with Swift's canonical `<`. The fetchers, caches,
actors and the JSON shape reading stay in Swift; `stateBBoxes` stays too,
because `roadClosures` still reads it for its state pick (its Rust twin
`STATE_BOXES` serves the containment test).

## Wave 2, fourth landing: stops along the route (2026-09-16)

Everything the stop buttons decide is Rust: `flows_core::places` holds the
route's nearest-vertex grid and cumulative meters, every kind's ranking
(food soonest reachable, fuel by fill plus detour cost, hotels by value,
parking by cost tier, stores by rating then brand), the name tables, the
FPS1 offline-places reader and its nearby query, the store's cross-shard
merge, and the stop search's rules: each kind's detour cap, search box,
shard groups and fallbacks, the search centres, the result dedup, the habit
pins and the everyday-first merge, the route thinning and the shower brand
pick. The route crosses once per leg as an opaque `FlowsRoutePath`. A shard
is an opaque `FlowsPlacesIndex` that holds only the offset tables: the
shard's bytes stay in the memory-mapped `Data` and are lent to each query,
so a 60 MB state shard stays clean file-backed pages instead of becoming a
copy.

The oracle (11,204 records, 27 kinds) is bridge-linked from 0f8894b and
matched on the first run, including 108 queries against the tool-built
Wisconsin shard. `POIService`'s private `rank`, `merged`, `rowKey` and
`corridorAhead` were observed through an access-only `sed`; the pieces
inline in `search`, which runs MapKit searches, are unit-tested helpers.
Text lists cross as one joined string plus each text's UTF-8 length, so a
place name holding any character splits back exactly. What stays in Swift:
the MapKit requests, the ratings and price providers, the published state,
the single-kind row decorations, and `POIRanking.meters` with its ~85
callers (wave 3).

## Review fixes: what the oracles could not see (2026-09-16)

A review read every facade switch since the wave-1 scaffold for mistakes a
user would notice that a bit-exact oracle cannot catch: the oracles pin
answers, not cost or identity. It confirmed three regressions, and this
landing fixes them and one smaller defect.

- **The Mexico fuel files.** The Foundation-style search rebuilt the whole
  file's cluster boundaries for every tag it looked for, and the price
  searches spanned the whole file where the Swift looked inside one station.
  Measured in release, 300 stations took 10.8 s; a real 13,000-station file
  would have taken hours, holding the price actor and every Mexican fuel
  search behind it. `swift_text::ClusterIndex` segments a text once for many
  searches, with every answer equal to `find_in` (checked exhaustively over
  edge texts and all offset pairs). The CRE parsers, the AAA page parser,
  `components` and `replacing` use it. 13,000 stations now parse in 0.55 s,
  and a test keeps the parse linear. The oracle's largest file had 8
  stations.
- **The ZIP overlay.** Every viewport change built entries with fresh UUIDs,
  so the map redrew every polygon on each camera settle. An entry's identity
  is now its bundle index.
- **Route scoring.** The per-sample loop on the main actor laid the
  corridor's gauges, water points and closures out for the bridge again at
  every sample. They are laid out once per route (`PreparedGauges`,
  `PreparedPoints`, also in the navigation watch and the map sweep), and the
  alert join lays the alert rings out once per join (`PreparedAlertRings`)
  instead of once per cell. Only gauges at or above flood stage are kept,
  which are the only ones the scorer counts.
- **The risk bundle's JSON fallback.** A one-ZIP bundle with no summary, or a
  text holding U+001F, split wrongly and failed to load, and a refused bundle
  stopped the candidate search. Text columns now cross by length, and a
  refused bundle moves on to the next candidate.

One claim was refuted: a same-rank alert that cannot replace the imminent
banner is the owner's rule from ded56c1, not a port defect (listed below as
an owner question). Left as it is: the map sweep copies each fetched
snapshot into Rust once per camera settle, a cost proportional to the feeds
paid once per sweep, not per point.

## Wave 2, long tail, first landing: devices, playback and other ways to travel (2026-09-16)

The decisions in ten small files are Rust. `flows_core::media_policy` holds
how healthy the data link looks (`SignalQuality`), how hard the device may
work for its thermal and power state (`AdaptiveTuning`), what plays when the
signal drops and when to switch back (`PlaybackFallback`), how long to wait
out a player's buffer (`PlaybackGrace`) and which NOAA transmitter to follow
(`RadioTuning`). `flows_core::travel_modes` holds the nearest Amtrak
station, the breadcrumb trail's recording rule and way-back distance, the
plane option's timing, fare and airport pick, the rush-hour traffic-check
cadence, the outlined risk areas (clusters and padded hulls), transit fares,
and the walk-plus-ride offer with its drop-off geometry. Spoken sentences,
ticket and ride links, the stored trail and the platform reads (radio
technology, other apps' audio, thermal state) stay in Swift.

The oracle (7,161 records, 34 kinds) is bridge-linked from bea472d and
matched on the first run. The breadcrumb trail was driven through a real
`BreadcrumbTrail` instance with its secure store stubbed, so the harness
never read the user's saved trail or keychain.

### Wave 1, corrected

The wave-1 table says the alert group was done by hand. That covered
HazardStyle, ShelterPolicy and ImminentAlerts. Three files the plan listed
under alert text and safety policy were never ported: `EscalationPolicy`,
`AlertEntityParser` and `ScannerIncidents`; they are the next landing. An
inventory of the Core files that still make no bridge call also turns up
files the plan never classified, which need a decision before wave 3:
`RiskAdvice`, `WMOAlerts`, `InternationalWeather`, `BadgeClustering`,
`ManeuverSymbol`, `VoiceReply`, `IntentClarifier`, `SiriSummaries`,
`TouristInfo`, `VehicleTrack`, `CameraZoom`, `GoldenScale`, `TextScale`,
`ZipBordersAndTransit` and `TruckerRadio`, besides the platform files
(networking, audio, speech, sensors, stores) that stay.

### Wave 2 remaining

| item | state |
|---|---|
| the NWS forecast predictors (`ForecastConditions.forecastScore`, `predictorFamilies`) | LANDED (second landing) |
| LiveHazardFeeds, WeatherAlertService, PrimarySources interpretation | LANDED (third landing); the fetchers' own selection logic (`roadClosures` state pick, provider chains) stays with the network code |
| POIRanking, PlacesStore (FPS1), POIService decisions | LANDED (fourth landing); the MapKit search, the providers and the row decorations stay with the service |
| the long tail | FIRST LANDING: SignalQuality, AdaptiveTuning, PlaybackFallback, PlaybackGrace, RadioTuning, AmtrakStations, BreadcrumbTrail, AirTravel, Mobility, HybridWalk. Not started: OfflineCorridors, recents, FuelWarning, transit estimates (TransitItinerary), spoken replies (VoiceReply), TripShare, VehicleLink, RouteAttributes, RadioBrowser |
| wave-1 leftovers | not started: EscalationPolicy, AlertEntityParser, ScannerIncidents |
