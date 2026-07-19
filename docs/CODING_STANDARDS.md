<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — coding standards (performance + resource SOP)

Standing operating procedure for the Rust core, the Swift app, and the R
reference implementation. These are not aspirations — they are how code gets
written here, verified by the test harness and the resource governor.

---

## 0. The stack rule: Rust + Swift, nothing else in the product

The product ships exactly two languages: **Rust** (core algorithms, data
pipelines, on-device training) and **Swift** (the app). No Python, no JS, no
interpreter of any kind runs in or ships with the product. Python remains
legitimate as *repo tooling* — verification scripts, one-off data checks — but
never as a runtime dependency or a build step the product needs.

Hand-written **AArch64 assembly** is not a shipping language but a last-resort
*technique* (§1): legitimate, but a hand kernel earns its place only by
**measurably beating** the compiler, and one that stops winning is deleted. As
of 2026-07 nothing ships through `asm!` — the sole kernel was retired (§1). The
doctrine stays; the bar is what keeps it honest.

The same rule extends to crates: prefer zero dependencies where std suffices.
`rust/flows-train` (the on-device-model trainer and the national-bundle
generator) is **pure std — its `[dependencies]` section is empty** — including
its own JSON reading/writing. A dependency is a liability we take only when
owning the code would be worse (see the memory rule: reduce dependencies, own
our tools).

**Corollary — dead code is deleted, not kept "just in case."** A fast variant
with no caller rots and misleads. The `risk_band` branchless/bsearch variants
and the distance NEON/autovec kernels were removed once nothing shipped
through them; `rust/flows-core/src/risk.rs` keeps only the scalar `risk_band`
reference (oracle-tested against R), and `rust/flows-core/src/distance.rs` is
the scalar `distance_matrix_scalar` reference with a documented SIMD seam for
the day a profile demands it. The *techniques* below remain SOP — they apply
to code that actually runs, not to museum pieces.

---

## 1. The optimisation tier ladder

Reach for the lowest-effort tier that hits the measured target. Never skip to
a lower tier speculatively — every descent must be justified by a profile.

| Tier | When | How |
|---|---|---|
| **Algorithmic** | First, always | Better complexity beats any micro-opt (e.g. contraction hierarchies vs flat A\*). |
| **Scalar clean** | Default | Tight loops, no allocation in the hot path, cache-friendly access, structure-of-arrays where it helps the vectoriser. |
| **Branchless** | SOP for hot classifiers | Replace data-dependent branches with arithmetic + table lookup so the branch predictor has nothing to mispredict. |
| **SIMD (NEON / std::simd)** | Static hot loop, data-parallel math | ARM NEON intrinsics (Apple Silicon) or portable `std::simd`. Held byte-identical to scalar by tests. |
| **GPU (Metal / wgpu)** | Very large dense matrices | 32 Metal cores for CONUS-scale distance/CH work. Same accuracy (f64), gated on min-size so small matrices stay on CPU. |
| **Hand assembly (`asm!`)** | Last resort | ONLY for a *static* hot loop where a flamegraph proves it dominates AND the SIMD form still leaves cycles on the table. The hand kernel must **measurably beat** the compiler's output — statistically-significant, measured, never speculative — and a kernel that stops winning is deleted (see below). |

### On assembly specifically

Assembly is a valid tool — for a hot loop that is **relatively static** (the
math doesn't churn) and gives a **statistically relevant** boost over the
SIMD form. That is a narrow, measured window: write the NEON/SIMD kernel
first, benchmark it, and only drop to `asm!` if the numbers demand it and the
kernel is stable enough that hand-tuned assembly won't rot. Most kernels
never qualify — LLVM's scheduler and register allocator are very good — but
the door is open when a profile mandates it.

**Worked example — the retired kernel (2026-07-19).** For a while the one
shipping `asm!` kernel was the polyline varint decoder (`decode_deltas_asm`).
It stopped earning its place: the pure-std bake-off in
`rust/flows-core/src/bin/bench.rs` measured the hand kernel at **3.20 ns/byte**
against **2.59** for the portable raw-pointer Rust body — rustc out-scheduled
it. Per this very standard (a flamegraph must prove it dominates; measured,
never speculative), the assembly was deleted. `decode_deltas()` now ships the
portable raw-pointer body on **all** targets, still pinned byte-identical to
the safe oracle `decode_deltas_rust` by the equivalence tests. Zero `asm!`
kernels ship today — and that is the standard working exactly as designed, not
a retreat from it.

---

## 2. Branchless is the default for hot classifiers

Any function that classifies millions of values per build (risk bands, colour
bands, feature gates) is written branchless. Historical example —
`risk_band_branchless`, which lived in `rust/flows-core/src/risk.rs`:

```rust
let finite = score.is_finite() as u8;
let g = (score >= RISK_GREEN_MIN)  as u8;
let y = (score >= RISK_YELLOW_MIN) as u8;
let r = (score >  RISK_RED_MIN)    as u8;
let idx = (finite * (g + y + r)) as usize;   // 0..3, no data-dependent branch
BANDS[idx]                                    // table lookup, not a jump chain
```

Rule: the branchless form is always accompanied by a test proving it equals
the readable reference on a dense domain sweep + all boundaries. If they ever
diverge, the branchless form is wrong and does not ship.

**Superseded (2026-07):** the branchless and bsearch `risk_band` variants were
deleted under the dead-code corollary (§0) — nothing on the shipping path
called them, so only the readable scalar `risk_band` (still oracle-tested
against the R band labels) remains in `risk.rs`. The pattern above is still
the SOP for the next classifier that *does* sit on a hot path.

---

## 3. Many small files, never a monolith

Code is organised as small, single-responsibility files, not one giant
module. This is already the discipline:

- R: 38 modules in `R/`, each one concern (`scoring.R`, `families.R`,
  `wi511_*.R` split thematically, `resource_governor.R`, `region_config.R`).
- Rust: `flows-core` is split `risk.rs` / `distance.rs` / `polyline.rs` /
  `routing.rs` / `scoring.rs` / `ch.rs` / `ffi.rs` / `lib.rs` plus a
  `transit/` module tree, and grows by adding files, not by growing files.
- Swift: `apple/FLOWS/Sources/Core/` is one file per concern —
  `RiskEquations.swift`, `ClimateProfiles.swift`, `SeasonalRiskModel.swift`,
  `BadgeClustering.swift`, `TowingLimits.swift`, `LiveHazardFeeds.swift`, and
  ~45 siblings — with UI in `Sources/UI/`. New capability = new file.

Benefits that matter here: faster incremental compiles (Rust recompiles only
the changed file), smaller diffs, cleaner ownership, and — critically for the
memory ceiling — the compiler and the editor hold less in memory at once.

Rule of thumb: a source file over ~400 lines is a smell; look for the seam.
When a file grows two distinct responsibilities, split it (as `wi511.R` was
split into nine files).

---

## 4. Drop from memory the moment it stops being relevant — no malingering

Large objects are released immediately after their last use, not left to
linger until scope end or GC.

- **R**: explicit `rm(big_object)` after last use + `release_runtime_memory()`
  at stage boundaries in the build pipeline. The band loop in
  `finalize_zip_view` drops each band's working frame before the next. The
  driving overlay drops the modelled frame after the concat. This is why the
  build holds ~1 GB and not the sum of every intermediate.
- **Rust**: RAII makes this the default — a value is freed at end of scope —
  but for a large buffer whose scope outlives its usefulness, an explicit
  `drop(big)` frees it early. Prefer tight scopes (`{ ... }` blocks) so the
  buffer's lifetime *is* its usefulness.
- **Both**: stream where possible instead of materialising a whole dataset.
  At CONUS scale the per-state reference loader loads only states in view and
  drops them on pan-away (Phase 2), rather than holding all 50 states.

The resource governor (`R/resource_governor.R`) enforces the ceiling this SOP
serves: `dynamic_mc_cores()` won't fork workers that would exceed 90% used,
and the continuous runner waits for headroom. Dropping promptly is what keeps
headroom available.

---

## 5. Lookups: the search hierarchy (binary search is the default *search*)

Ordered fastest → slowest. Use the fastest form the data structure allows;
never scan linearly.

1. **Direct O(1) index / perfect hash** — `array[idx]` when the index is
   computable, or a hash map. This is *faster than binary search* and is the
   only case where binary search would be a downgrade. R's `match()`,
   `%in%`, and named-vector `v["key"]` are hash-backed O(1) — leave them;
   converting them to binary search would be slower.
2. **Binary search O(log n)** — the **standard for any genuine search over
   sorted data**. In R use `findInterval` (a C-level binary search over
   sorted breakpoints); in Rust use `slice::partition_point` /
   `binary_search`, which are **implemented branchlessly** (conditional-move),
   so they satisfy the branchless + no-loop SOP simultaneously. A linear scan
   over sorted data (`which(sorted <= x)[1]`, a `for` loop breaking on match)
   is a defect — replace it.
3. **"Binary within a binary search" / hierarchical** — for multi-key or
   spatial lookups. A 2-D range query is a binary search on one axis nested
   inside another; the standard realisation is a **k-d tree / R-tree**, which
   is exactly what `sf::st_intersects` / `st_nearest_feature` use (39 call
   sites already). Do not hand-roll a nested scan where a spatial index
   exists. **In Swift, where no library index applies, the house pattern is
   the uniform lat/lon cell grid**: bucket points into `Dictionary<cell,
   [index]>` at build time, then answer a query by scanning only the query's
   cell and its neighbours (or expanding rings until no unscanned ring can
   hold a closer point). Shipped instances: `RoutePath.nearest`
   (`Core/POIRanking.swift` — expanding-ring, proven identical to the full
   O(V) scan including tie-breaks), the 0.2° entry grid behind
   `RiskFieldService.selectZips` (`Core/RiskFieldService.swift`), the shower
   city tables, and the seasonal-model hub lookup. A per-query linear scan
   over all points is the same defect as (4) below.
4. **Linear scan O(n)** — **banned as a search.** The only O(n) passes that
   remain are (a) building the sorted array in the first place, and (b)
   *extremum finding on unsorted data* (`which.max` / `which.min` over a score
   vector) — where binary search is genuinely impossible because the data
   isn't sorted and sorting first (O(n log n)) is worse than the single pass.
   Those are the "impossible otherwise" cases; document them as such.

Worked example — `pick_forecast_period` (`R/forecast.R`) was a linear
`which(starts <= target & ends >= target)` over the *chronologically sorted*
NWS hourly periods. It is now a `findInterval` binary search with a
neighbour-only closest fallback, guarded to fall back to the exact linear
semantics on non-monotone data, and verified byte-identical to the original
across 500 synthetic period sets. Honest caveat: the O(n) *time-parse* still
dominates this particular function — the binary search matters more for the
larger sorted lookup tables in the CONUS work (per-state index bounds, gauge
threshold arrays, legend stops).

Rust example — `risk_band_bsearch` (`rust/flows-core/src/risk.rs`) classifies
a score via `partition_point` over the sorted cut table: a binary search that
is also branchless and loop-free, held byte-identical to the arithmetic
reference on a dense domain sweep.

## 6. Avoid loops whenever you can

A loop is the last resort, not the reflex. Prefer, in order: a vectorised
whole-array operation (R vectorised functions, Rust iterator chains that LLVM
fuses), SIMD, a binary search / index (§5) instead of a scan, or a table
lookup. Where a loop is unavoidable (streaming a feed, a fixed tiny fallback
list), keep it branchless and vectorisable, and make sure it is not standing
in for a search that a sorted structure could answer in O(log n).

## 7. Cause and effect, measured — never assume a speedup

Every optimisation is a hypothesis with a before/after measurement, recorded
in `data/results/experiments.jsonl`. The route-latency assumption
("intrastate < 1 s") was *refuted* by measurement (p50 2.7 s) — that is the
process working. A change that "should be faster" but isn't measured did not
happen. The continuous runner re-samples the distributions so a regression
shows up as a shifted p95, not a lucky single run.

---

## 8. Accuracy is never traded for speed silently

Every faster path (branchless, SIMD, GPU) is held **byte-identical** (or
within a documented float tolerance) to the readable reference by a test:

- `decode_deltas` == `decode_deltas_rust` on 2,000 random + malformed inputs
  (the portable raw-pointer body vs. the safe Rust oracle — the equivalence
  tests outlived the retired `asm!` kernel they were first written for).
- `euclidean_distance_matrix` GPU path == CPU `outer()` (R oracle).

If a fast path can't be proven equal to the reference, it does not replace
the reference. Speed that changes the answer is a bug, not an optimisation.
