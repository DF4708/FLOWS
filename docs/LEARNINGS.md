<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — captured learnings

Non-obvious facts, footguns, and design principles discovered while
building the current codebase. If any of these get forgotten, the class
of bug they prevent tends to come back.

---

## Table of contents

1. [R language footguns](#1-r-language-footguns)
2. [Cache + snapshot invariants](#2-cache--snapshot-invariants)
3. [Fork safety](#3-fork-safety)
4. [Safety vs throughput discipline](#4-safety-vs-throughput-discipline)
5. [Sanitiser + boundary invariants](#5-sanitiser--boundary-invariants)
6. [Performance patterns](#6-performance-patterns)
7. [Progress UX invariants](#7-progress-ux-invariants)
8. [Testing patterns worth keeping](#8-testing-patterns-worth-keeping)
9. [Resource governance (memory ceiling + accelerator honesty)](#9-resource-governance-memory-ceiling--accelerator-honesty)
10. [Native app learnings — 2026-07](#10-native-app-learnings--2026-07)

---

## 1. R language footguns

### `nzchar(NA_character_)` is TRUE on this R install

The single most expensive bug we hit. Anywhere a boolean guard used
`nzchar(x)` on possibly-NA input, the guard passed and NA leaked into
the downstream vector-indexing operation, producing `"NA 0%"` popups
and `NA` reason strings.

**Rule**: always gate on `is.na(x) BEFORE nzchar`.

```r
# Wrong: nzchar(NA) is TRUE here
if (nzchar(family_name)) sprintf("%s %s", family_name, pct)

# Right: anchor on !is.na(x) first
if (!is.na(family_name) && nzchar(family_name)) sprintf(...)
```

Codified in `is_nontrivial_string` in `R/util.R`.

### `as.character()` strips names from a named character vector

Killed the popup for ZIP 53713 — `sanitize_transport_reason` called
`as.character(reason_text)`, which stripped `names()`, and every
downstream `out_reasons["53713"]` returned `NA` because the vector was
unnamed. Score path (`out_scores["53713"]`) still worked because it was
a named numeric that hadn't been coerced.

**Rule**: after any `as.character()` on a named vector, restore names
explicitly.

```r
sanitize_transport_reason <- function(reason_text) {
  txt <- as.character(reason_text)
  if (!is.null(names(reason_text))) names(txt) <- names(reason_text)
  txt[is_travel_delay_reason(txt)] <- NA_character_
  txt
}
```

### `%||%` catches NULL, not NA

`x %||% "fallback"` is the standard defensive pattern in this codebase.
It short-circuits only when `x` is NULL. `NA %||% "fallback"` returns
`NA`, not `"fallback"`. Anywhere the value can be either, use both:

```r
value <- x %||% NA_character_
if (is.na(value)) value <- "fallback"
```

### `as.POSIXct(x, tz = "UTC")` truncates ISO-8601 with colonized offsets

The default POSIXct parser doesn't accept `"2026-05-05T05:00:00-05:00"`.
It silently truncates to `2026-05-05 00:00:00 UTC` and every hourly
forecast period parses to the same midnight. `pick_forecast_period(0)`
then picks the wrong "now" period — for ZIP 53713 this surfaced as a
22-hour-future 45 °F reading on the live popup.

Fixed in `parse_iso_time` (`R/alerts.R`): strip the offset colon before
`%z`, try multiple formats. Test coverage in `tests/sqa_runner.R` gate
[7].

### `for (i in 1:n)` fires with `n == 0`

`1:0` yields `c(1, 0)` — the loop body runs twice with `i = 1` and
`i = 0`. Use `seq_len(n)`.

### `rep(NA, n)` produces a logical NA

`NA` without a type suffix is `NA_logical_`. Compared to a numeric
vector it upcasts; compared to a character it downgrades. The pattern
`rep(NA_real_, n)` / `rep(NA_character_, n)` is what you want when
seeding a typed column.

### `if (NA)` throws

Any boolean guard that produces `NA` blows up. `if (any(mask))` with
a partially-NA mask is safe because `any(TRUE, NA)` is TRUE; but
`if (mask[i])` with `NA` at position `i` throws
`"missing value where TRUE/FALSE needed"`. Anchor masks on
`!is.na()` upstream.

---

## 2. Cache + snapshot invariants

### Three-tier cache, three different lifetimes

- **In-process** (`live_cache` env, `R/cache.R`) — TTL-bounded (typically
  90 s for alerts, 15 min for forecast layers). Lost on restart.
- **Disk snapshots** (`data/runtime_cache/*.rds`) — regenerable, tied
  to a content-hashed cache key. Gitignored. Warm start reads these.
- **Reference data** (`data/reference/*.gpkg`, `*.rds`) — long-lived,
  offline-built by `scripts/build_wisconsin_reference_assets.py`.
  Tracked in git.

Never mix. Anything that could ever contain PII, per-session state,
or a horizon-specific value goes into the first two — never `data/reference/`.

### Cache-key must include everything the value depends on

Multiple regressions from cache-key omissions:

- The 511 road overlay cache key includes a `road_511_sig` hash of the
  current 511 state so a stale 511 update doesn't get served alongside
  fresh polygons.
- The external bundle cache key includes `include_transport` — a bundle
  built without transport must not satisfy a request that needs it.

**Rule**: before adding a cached output, list every input it depends
on; every listed input must appear in the key.

### Named vectors survive cache round-trips only if you don't `as.character()` them

See [1: as.character strips names](#ascharacter-strips-names-from-a-named-character-vector).
Cached `out_reasons` is a named character vector; the sanitiser call at
`compute_511_zip_transport_risk`'s output boundary was the site of the
bug that hid it.

### Snapshots must never contain stale operational text

The startup snapshot on disk has already-styled roads and already-
composed popups. When the safety-vs-throughput audit landed, the old
snapshot still had "511WI travel delay …" strings baked into modeled
road popups.

**Rule**: at every snapshot read boundary that produces user-visible
text, run the current sanitiser. See `load_startup_map_snapshot` in
`R/snapshots.R`.

---

## 3. Fork safety

### Load native libs in the parent BEFORE the first fork

macOS forks silently segfault during `dyn.load` if the child is the
first process in the tree to need `curl` / `httr2`. The parent process
must eager-load them.

```r
# scripts/warm_live_startup_snapshot.R (top)
suppressWarnings(suppressMessages({
  invisible(tryCatch(curl::curl_version(),         error = function(e) NULL))
  invisible(tryCatch(curl::curl_parse_url("https://x/"),
                                                    error = function(e) NULL))
  invisible(tryCatch(httr2::request("https://x"),  error = function(e) NULL))
}))
```

Codified as **iter 7 / iter 9** in the earlier optimisation log — once
fixed, `mcparallel` and `mclapply` became safe to use freely.

### mcparallel + mclapply nest cleanly

The 511 road prefetch fork uses `mcparallel` at the top and
`mclapply(mc.cores = 2)` inside — each `mclapply` child is a grandchild
of the main process. Works on macOS + Linux; Windows has no `fork()`
so the code falls back to sequential `lapply`.

### Detect soft failures, not just hard ones

`mclapply` silently returns `list(NULL, NULL, ...)` if children die.
The forecast-baseline retry logic distinguishes two modes:

- **Hard**: `is.null(x)` or `inherits(x, "try-error")` — retry.
- **Soft**: an `empty_forecast_result()` with `NA` temperature —
  API returned the shape but no data. Also retry.

Without the soft check, 35 % of ZIPs had NA temperatures for the entire
horizon TTL because the parent thought the fetch succeeded.

---

## 4. Safety vs throughput discipline

The single most important product-level principle in this codebase.

### Congestion is not a hazard

- **Travel delay** ("511WI travel delay elevated risk by 44 min over
  normal") is a *throughput* signal. Drivers face no additional safety
  risk sitting in traffic.
- **Flex lane closure** ("FLEX LANE CLOSED TO TRAFFIC") is an
  *operational* signal. Drivers in adjacent general-purpose lanes are
  not endangered.
- **Ramp metering active** — same category.
- **HOV / express / managed lane state** — same category.
- **Toll plaza cash-only** — same category.
- **Park-and-ride full** — same category.
- **Special-event traffic management** — same category.

None of these should paint a road red. All are filtered by
`is_operational_only_511_text()` (`R/wi511_sanitizer.R`) BEFORE
`score_511_*` scorers ever see the text.

### The safety carve-out

Mixed signals must fall on the safety side:

- `"FLEX LANE CLOSED CRASH AHEAD"` → operational filter checks safety
  keywords first, finds "crash", releases the text to the scorer, which
  fires on "crash" → 0.60. Correct.
- `"CRASH AHEAD"` → not operational at all → straight to scorer →
  0.60. Correct.
- `"FLEX LANE CLOSED"` (nothing else) → operational + no safety
  keyword → returns 0. Correct.

### "closed" needs road-scale context

Bare `closed|closure` triggered 0.90 on "FLEX LANE CLOSED". Now
`score_511_*_risk` requires
`road closed|highway closed|interstate closed|all lanes closed|
emergency closure|impassable|do not use`
in the freeform text, OR the structured `is_full_closure = TRUE` flag
from the events API.

### Route ETAs stay ETA-only

Real-time delay data must never leak into the risk overlay. The
routing system uses static `base_speed_mph` with a −5 mph penalty for
red-risk segments. If a future feature wants delay-aware ETAs, it must
route through a separate ETA path that never touches the risk column.

---

## 5. Sanitiser + boundary invariants

Every user-facing string that crosses a cache boundary passes through
a sanitiser. Two live now:

- `sanitize_transport_reason` (`R/wi511_sanitizer.R`) — strips legacy
  travel-delay strings; runs at (a) the compute output of
  `compute_511_zip_transport_risk`, (b) the persisted-bundle read path
  in `compute_external_risk_bundle`, and (c) the startup snapshot load
  in `load_startup_map_snapshot`.
- `is_operational_only_511_text` (`R/wi511_sanitizer.R`) — the
  score-boundary filter described above.

### The boundary rule

If you can name a value that (i) is written by an old process, (ii) is
read by a new process, and (iii) is displayed to a user, the read path
runs the current sanitiser. Snapshots outlive code fixes.

### Boundary threshold tests

`RISK_GREEN_MIN` is 0.398. The label function returns "Green" for
values ≥ 0.398 and < `RISK_YELLOW_MIN`. A test suite that only checks
0.1 / 0.5 / 0.7 / 0.9 misses off-by-one mutations that shift the
threshold to 0.4 (then 0.399 wrongly reports Transparent).

**Rule**: at every band boundary, include a test point just above and
just below the threshold. See `tests/mutation_test.R` oracle for
`risk_label_from_score`.

---

## 6. Performance patterns

### Vectorise per-row callers that show up in warm-cache profiling

Six functions in this codebase used to be scalar and were called via
`vapply(seq_len(n), function(i) f(df[i, , drop = FALSE]))` inside
`finalize_zip_view`. Each row-slice is a data.frame copy — the *slice*
was the cost, not the score logic.

Rewrote to accept the whole frame and return an n-length vector:

| Scalar (removed) | Vectorised (kept) | Speedup |
|---|---|---|
| `compose_risk_reason` | `compose_risk_reason_vec` | 23× |
| `compose_risk_component_summary` | `compose_risk_component_summary_vec` | 9× |
| `compose_risk_type_summary` | `compose_risk_type_summary_vec` | 9× |
| `risk_label_from_score` (was scalar switch) | vectorised mask assignment | ~50× |
| `risk_rgb_hex` (was scalar vapply) | vectorised mask assignment | ~50× |

### Bulk `st_distance` matrix beats per-row calls

Per-ZIP `st_distance(zip_pts_proj[i, ], signs_proj[idx, ])` inside a
loop over 861 ZIPs: ~75 s cold. Precompute
`st_distance(zip_pts_proj, signs_proj)` as one matrix, then index into
it inside the loop: 1.7 s.

The matrix is small (~861 × 10 = 8.6 KB) because upstream noise-floor
filters trim signs to ~10 rows. The pattern generalises: batch the
expensive geometry op once, cheap R indexing inside the loop.

### Dual-centroid + outer Euclidean for line-vs-line proximity

`st_distance(roads_proj, official_proj)` on 84 k roads × 50 official
overlay rows is O(N·M·verts). It ran 38–85 s in various iterations.

Replaced with centroid-vs-centroid Euclidean:

```r
road_cent <- st_centroid(st_geometry(roads_proj))
off_cent  <- st_centroid(st_geometry(official_proj))
rc <- st_coordinates(road_cent)
oc <- st_coordinates(off_cent)
# per road i, official j
x_diff <- outer(rc[, 1], oc[, 1], "-")
y_diff <- outer(rc[, 2], oc[, 2], "-")
d      <- sqrt(x_diff^2 + y_diff^2)
```

Sub-second. Loses ~200 m of accuracy vs true line-vs-line distance;
`exp(-d / 6000)` scoring absorbs the loss (< 2 % at d = 4 km).

### `sf::rbind` is slow — manual concat is faster

`rbind(modeled, official)` on 25 k + 70 rows: 970 ms. Replace with:

```r
df   <- rbind(st_drop_geometry(modeled), st_drop_geometry(official_std))
geom <- c(st_geometry(modeled), st_geometry(official_std))
out  <- st_sf(df, geometry = geom)
```

~330 ms. `sf::rbind` spends most of its time on attribute-class
reconciliation between the two frames; skipping that path pays.

### Parallel network I/O has diminishing returns above ~24 cores

NWPS gauges: 12 cores × 6 s timeout = 76 s worst case. Bumped to
24 × 4 s = 76 s worst case, but typical dropped from 62 s to 15–25 s.
Beyond 24 cores the NWPS endpoint throttles or the socket setup
dominates.

---

## 7. Progress UX invariants

### "Map ready" fires exactly once per fresh paint

The startup snapshot path serves cached polygons for an instant first
paint. If the band-render observer's `reset_progress()` fires on the
snapshot's render, the user sees "Map ready" while the *real* fresh
build is still computing in the background.

**Fix**: mark the snapshot payload `is_snapshot = TRUE`; the band
observer gates on `!isTRUE(payload$is_snapshot)`. The snapshot render
shows "Showing cached map — refreshing live data…" at 80 %; the fresh
render then fires "Map ready" at 100 %.

`invalidateLater(150, session)` in the snapshot return path forces the
reactive to re-run within 150 ms so the cold-path rebuild kicks off
promptly.

### Progress bar messages never mention a step that already finished

`notify_progress` is monotonic on `value`: `max(existing, new)`. That
prevents "Loading forecasts…" briefly re-appearing after a later step
already reported "Rendering band 8 of 10".

---

## 8. Testing patterns worth keeping

### Mutation testing is where you find the bug you'd never write a test for

The `nzchar(NA)` bug and the `as.character()` name-stripping bug were
both invisible to positive-path tests (correct data in, correct data
out). Mutation harness deliberately re-injects each class of bug and
checks that at least one oracle detects it.

### Two-oracle rule for boundary tests

For every band threshold, at least one test point sits *just* above
and *just* below. `0.398`, `0.399`, `0.5`, `0.699`, `0.700`,
`0.875`, `0.876` — not the round-number sample `0.1`, `0.5`, `0.9`.

### Custom static analyser is worth 30 lines

14 R-specific footguns (`== NA`, untyped `NA`, `1:n` zero-bug, etc.).
`tests/static_analysis.R`. Grep-and-report; not a full parser. Runs
in < 1 s. Currently finds 2 cosmetic untyped-`NA` reports that we've
audited as safe.

### Equivalence tests are how you refactor confidently

When we vectorised `build_modeled_road_risk_index`, the equivalence
test built a synthetic 1 500-row input and compared the vectorised
output column-for-column against a copy of the pre-fix scalar
implementation. Zero mismatches, ~25× speedup — merge with confidence.

Same pattern for the three `compose_risk_*_vec` functions.

---

## 9. Resource governance (memory ceiling + accelerator honesty)

Added when the user required "never pressure the system beyond 90% memory,
use the most underused resources (GPU/NPU cores) when possible and accurate."

### The macOS memory-pressure definition is not "free RAM"

`memory_pressure` reporting "19% free" does NOT mean 81% used in the sense
that matters. macOS keeps RAM full of reclaimable caches (inactive +
speculative pages). The metric that actually predicts swap/compression
thrash is **wired + active + compressed ÷ total** — what Activity Monitor
calls memory pressure. `R/resource_governor.R::system_memory_used_fraction`
computes exactly this from `vm_stat` + `hw.memsize`. On the M1 Max dev box
this read ~90% during a build while naive "free RAM" looked scarier.

### Dynamic core count must be bounded by memory, not just CPU

`parallel::detectCores() - 2` is the CPU cap. But each `mclapply` fork copies
the parent RSS, so N forks with large `sf` objects in memory can blow the
ceiling while CPU sits idle. `dynamic_mc_cores()` sizes workers by
`(ceiling - used) * total_gb / mem_per_worker_gb`, clamped to the CPU cap.
Under real pressure it correctly returned **1** where `detectCores()-2` would
have said 8. Network-I/O fan-outs (NWPS gauges, region forecasts) pass a
small `mem_per_worker_gb` (~0.25) so they keep their full core count under
normal memory and only throttle under genuine pressure.

### GPU: real, but only for one op class, and only when a real backend exists

The M1 Max has 32 GPU cores (Metal 4). R reaches them **only** through a
tensor library with an MPS backend — `torch` is the viable one. It is **not
installed** by default (`gpuR`/`GPUmatrix`/`clblast` also absent). So the
honest posture: `compute_backend()` returns `"gpu"` **only** when torch+MPS
is genuinely available, else `"cpu"` — never a fabricated claim.

The ONE FLOWS hot-path op that maps accurately to the GPU is the dense
Euclidean distance matrix (`outer()` blocks in the proximity/sign signals,
and future contraction-hierarchy batch shortest paths). It is now behind
`euclidean_distance_matrix(A, B)`, which is **byte-identical float64** on CPU
and GPU (verified `all.equal`), with a min-size guard so small matrices stay
on CPU (host↔device transfer would dominate). Installing torch later flips
these to the GPU automatically with zero numeric change.

What does NOT map to the GPU: GEOS geometry ops (CPU-only C++ library) and
A*/Dijkstra graph traversal (inherently sequential, branch-heavy — poor SIMD
fit). Do not force these onto the GPU; it would be slower and no more
accurate.

### NPU / Neural Engine: cannot run FLOWS' math — do not claim it

The 16-core Apple Neural Engine is **fixed-function ML-inference silicon**
reachable only via CoreML. It executes convolution / matmul graphs for
trained models. FLOWS' hot path is geometry + graph search with **no ML
model**. There is no accurate way to route these calculations to the ANE —
claiming NPU acceleration here would be false. If a future FLOWS feature
adds an actual ML model (e.g. a learned ETA or hazard-nowcasting model),
that specific inference could target the ANE via CoreML — but nothing in the
current pipeline qualifies. Honesty over a checkbox.

*(Superseded in part, 2026-07: FLOWS now DOES carry on-device learned models —
`SeasonalRiskModel` + a `LearnedHead` MLP trained by `rust/flows-train` — so
the "no ML model" premise no longer holds for the Swift app. The honesty rule
stands: only claim an accelerator when a real backend runs on it.)*

---

## 10. Native app learnings — 2026-07

Discovered while shipping the native Swift/MapKit app
(`apple/FLOWS/Sources/`). Same spirit as sections 1–9: each of these cost
real debugging time and will bite again if forgotten.

### MapKit polygons render no pattern fills

SwiftUI `MapPolygon` silently ignores `ImagePaint` stripe tiles — you get a
flat fill (or nothing), no error. There is no supported way to pattern-fill
a map polygon. The risk-area hatching is therefore drawn as geometry:
`ContentView.hatchLines` (`apple/FLOWS/Sources/UI/ContentView.swift`)
generates parallel line segments clipped to the polygon ring and renders
each as a `MapPolyline`, alternating risk-color / hazard-type stripes over
a transparent polygon.

**Rule**: on MapKit, "texture" must be built from polylines/polygons, never
from paint styles.

### Walking router: return `[]`, don't throw

`MKDirections` errors outright on long pedestrian asks (Apple rejects
long-distance walking requests). `RouteService.planRoutes(walking:)`
(`apple/FLOWS/Sources/Core/RouteService.swift`) therefore issues ONE
pedestrian request (the three driving strategies are identical under
`.walking` — concurrent copies just wasted requests) and returns `[]`
instead of throwing on failure. Returning empty — not error — is what lets
the caller's driving fallback plus the `plannerNotice` banner engage
uniformly; a thrown error would surface as a failure instead of a graceful
"showing driving route instead" downgrade.

**Rule**: when a fallback path exists, an empty result is a better contract
than an exception — the caller's degrade logic runs either way.

### WZDx: an open registry beats N hand-configured DOT feeds

DOT road closures come from the WZDx open-feed registry on
data.transportation.gov (public Socrata JSON) rather than hardcoded
per-state URLs — `LiveHazardFeedFetcher` (`Core/LiveHazardFeeds.swift`)
fetches the registry at most once per day (`ensureWZDxRegistry`, and the
timestamp advances even on failure so a dead endpoint can't retry-storm),
then pulls keyless per-state GeoJSON feeds with a per-state cache.
Footgun found in the wild: registry field names have drifted across
versions, so the parser probes multiple candidate field names instead of
trusting one schema. Closures feed the `closure` PRIMARY risk family.

### Seasonal-normal gating: normal-for-here-and-season never draws

Presentation-layer principle. A 95 °F day is an alert in Seattle and
Tuesday in Phoenix. `ClimateProfiles` (`Core/ClimateProfiles.swift`)
classifies 12 Köppen-style climate types from lat/lon/elevation (replacing
1-D latitude bands for temp normalization — `LatitudeBands` is retained
only for R-parity scoring inputs), and `seasonalNorms(week:…)` interpolates
each type's winter/summer envelope with a week-of-year sinusoid.
`temperatureBeyondNormal` / `windBeyondNormal` gate the overlay: a reading
inside the local seasonal envelope draws nothing, however extreme it would
be elsewhere. This is a *display* gate — scoring inputs are unchanged.

**Rule**: hazard presentation must be normalized to local seasonal
climatology, or the map cries wolf across half the continent.

### Two-truths ranking: realized band ⊕ discounted identified exposure

Route ORDERING (never the display band) combines two kinds of evidence in
`RiskEquations.rankingRisk` (`Core/RiskEquations.swift`): the realized-risk
band (alerts + current conditions) and the IDENTIFIED ZIP exposure (modeled
field, then the on-device seasonal prior). A ZIP can carry known risk
before any alert fires, and an alert can fire in a historically clean ZIP —
both are evidence. Identified risk is discounted ×0.6 so a realized Red
always dominates, and the two combine noisy-OR so neither truth erases the
other. As the `SeasonalRiskModel` prior for this route/week accrues
confidence, it linearly takes over from the static field
(`z*(1-c) + p*c`). Companion rule (proof-not-prediction,
`RiskEquations.alertFamily`): warnings of in-progress danger map to PRIMARY
families that can reach Red alone; watches/forecasts map to predictor
families capped below Red.

### Quit-during-reinstall reads as crash

Dev-workflow footgun. The dev loop reinstalls the app constantly (and every
reinstall already wipes TCC grants unless the stable code-signing identity
from `apple/tools/make_signing_identity.sh` is used). If the running app is
quit/killed while its binary is being replaced by a reinstall, macOS logs
the termination as an unexpected exit — it shows up as a "crash" in
Console/crash reports even though nothing crashed. Cost time chasing
phantom crash reports that were just the install step tearing down the old
process.

**Rule**: after a reinstall cycle, a crash report timestamped at install
time is noise. Only investigate crashes that occur while the (re)installed
build is actually running.

### 10.1 Full-codebase review (2026-07-10) — deferred findings register

Fixed in the same pass: nav-pan camera fight (drag gesture beats the 1 Hz
stamp heuristic), invisible ImagePaint fills on alert polygons/corridor
circles, `weatherScored` honoring `CorridorScore.complete` + one retry pass,
US–MX border misclassification (Rio Grande diagonal), custom trucker_radio.json
survival, range-EMA alpha (50 s → ~55 min), ClimateProfiles negative-key
decode, tsunami per-entry classification, WZDx per-feed caching + dedupe,
flash-flood warning-only realization, LearnedHead bounds, RiskFieldService 5×5
neighborhood, reroute-task lifecycle, brand-match tightening, Yelp term
encoding, HOS stationary-fix speed guard, towing-banner clear, badge identity,
sweep retry/cancellation.

Deferred-findings register — CLOSED OUT 2026-07-11 (all fixed except the
last, deliberately accepted):
- addStop() false final-arrival: FIXED — arriving at an added stop with no
  continuation leg now replans from the stop; never fires the final banner
  or a bogus trip record.
- Escalation like-for-like: FIXED — the live monitor now compares the same
  distance-weighted mean the baseline uses (the old peak⊕avg blend sat above
  the weighted baseline by construction), tripObservedPeak records the true
  peak sample, and a realized RED anywhere in the window escalates on its own.
- POIService search race: FIXED — generation counter; superseded searches
  can't clear isSearching or repopulate stale results.
- NavigationEngine.advance(): FIXED earlier (windowed match).
- corridorHazardShapes clustering: FIXED — badges computed once per route
  change alongside the corridor ZIP areas, stable identity, off the render
  path.
- First rebuildRiskOverlays stale-ring pairing (~1 s visual): ACCEPTED —
  self-corrects on ring resolution; a fix would delay first paint.

## 11. The Wisconsin R engine retired — one system (2026-07-11)

The original R/Shiny engine (43 modules) was REMOVED from the repo along with
its scripts, test harness, and Wisconsin reference assets. Rationale: the
native app + Rust core had reached parity-or-better on every axis (national
20-year history vs. WI-only live scoring; week-correct harmonic priors;
identical live feeds), and running two scoring systems made WI present
differently from every other state — the exact dual-system inconsistency
worth eliminating. What survives:

- **The oracle guarantees**: R-generated fixtures stay pinned in the test
  suites (RiskEquationVectors.swift, polyline triple-identity) — byte-identity
  is enforced against the FROZEN reference, not a live runtime.
- **The bundle**: regenerated with zero preserved specials — 33,300 ZIPs, no
  polygon rings (ZCTA boundaries come on demand for all states equally), WI's
  783 ZIPs scored from the same 20-year history as everyone else's.
- **The continuous runner**: R gates replaced by a memory-and-mtime-gated
  Swift suite gate alongside the existing governed cargo gate.

Recovery note: the full engine is in git history (`git log -- R/`).

## 12. QA pass: latency + the macOS first-click swallow (2026-07-12)

A user-level QA drive (aesthetics, latency, menu navigation, missing data)
found two systemic defects. Both fixes are mechanisms, not patches.

### GO was hostage to the slowest public feed

`scored()` was monolithic: the GO gate keys on the weather verdict, but the
function also awaited EPQS grades, Overpass clearances, FEMA zones, and EV
gaps before returning. The night EPQS went down (it fails by HANGING, not
erroring), "Scoring…" never resolved. Two-layer fix:

- **Split hydration.** `scored()` now ends at the safety verdict
  (`weatherScored`); `attributeScored()` runs as a second pass that patches
  the choice card — or the LIVE leg via `NavigationEngine.
  updateRouteMetadata` — whenever it lands. GO unlocks in ~30 s on a 400-mi
  corridor; grades/bridges hydrate behind it ("checking…" → value or an
  honest "no data"). `startLeg` self-hydrates any leg that arrives
  attribute-pending (reroutes, added stops, arrival chaining) — one hook, not
  per-call-site plumbing.
- **Per-host circuit breaker in `ThrottledNet`** (`HostBreaker`). A dead
  host's zombie sockets each held an app-wide permit for the full 10 s
  timeout — 300 queued EPQS calls starved every HEALTHY feed for minutes.
  The breaker check runs AFTER permit acquisition (a queued call to a host
  that died while it waited must fast-fail), trips after 5 straight
  transport failures, and admits exactly ONE probe after cooldown. Any HTTP
  response is a success at this layer — status handling stays with callers.
  Corollary: `elevation()`/`highRiskFloodZone()` no longer negative-cache —
  an outage tonight must not read as "no data here" forever.

### The first click after typing did nothing

Three stacked causes on macOS, found by peeling one layer per repro:

1. **Inline predictions** sit as MARKED text in the field; the click that
   dismisses them never reaches its target, and the next keystrokes replace
   the marked range ("Nashville, TN" → "Nashville, Augusta, GA"). SwiftUI
   has no per-field switch; the app opts out via AppKit's defaults keys
   (`NSAutomaticInlinePredictionEnabled` / `NSAutomaticTextCompletionEnabled`)
   — right for FLOWS, where every input is a place name, ZIP, or vehicle spec.
2. **Launch-time main-thread work** delayed focus moves long enough to drop
   keystrokes: the 33k-zip harmonic rescore and grid build ran on the main
   actor inside `RiskFieldService.load()`. Moved into the detached parse task.
3. **SwiftUI-native fields consume the session-ending click entirely** — the
   button action, `simultaneousGesture`, and an `NSEvent` local monitor all
   never see it (there is no AppKit field editor to end). The fix that works:
   a real `NSView` overlay (`FirstClickCatcher`) on the Plan button receives
   the raw mouseDown/mouseUp from AppKit dispatch ahead of SwiftUI's text
   machinery. Keyboard path: destination ⏎ walks to an empty start field,
   else plans; `plan()` is reentry-guarded.

Also: a card that peaks Yellow with no named hazard now says "elevated by
forecast conditions" instead of "All clear — no active alerts or elevated
conditions" (the band bar and the sentence must agree).

## 13. Signing, TCC persistence, and the cancellation trap (2026-07-13)

- **Ad-hoc signing re-prompts TCC forever.** macOS keys permission grants to
  the app's code-signing designated requirement; an ad-hoc signature's DR is
  effectively the CDHash of THAT build, so every rebuild looked like a new
  app and Location re-prompted. Signing with the real Apple Development
  identity (team-anchored DR: bundle id + cert CN) makes one grant persist
  across all future rebuilds. None of our entitlements are restricted, so
  local macOS signing needs no provisioning profile.
- **Cancellation is not a host failure.** The first HostBreaker counted every
  thrown error as a transport failure — including `URLError.cancelled` from
  a camera move superseding the viewport hazard sweep. At launch (GPS fix →
  map flies → mass-cancel) that opened the breaker on a HEALTHY
  api.weather.gov: bare risk map, cards spinning forever, and the one-shot
  6 s weather retry died inside the 120 s cooldown. Fixes: cancelled
  requests never count toward the trip, and the incomplete-weather retry is
  a backoff series (6/15/15/30/30/60 s) that outlives one breaker window.
  Symptom to remember: "everything network-ish silently empty right after
  launch" smells like the breaker, not the feeds.
- **A transit itinerary must call out a dominant access walk.** A suburban
  start with a downtown-only Greyhound stop produced "6 h 47 m" whose first
  leg was a 5 h 14 m WALK — labeled, but easy to read as a normal ride. The
  card now flags "Mostly walking: nearest stop is X on foot" whenever the
  access walk exceeds an hour and the ride itself.

## 14. The map was honest but LOUD (2026-07-13)

User feedback: "many flood warnings and a fire warning just between Augusta
and Columbia — is something exaggerated in the equations?" Ground truth at
that moment: ONE Special Weather Statement in all of SC, zero GA alerts.
The equations were right; the presentation lied three ways:

- **Rain probability wore the flood costume.** `dominantKind` fell through
  to the flood wave icon for plain forecast PoP — a 60% July thunderstorm
  chance badged as "Flood". PoP now gets its own `rain` kind ("Rain
  chance", cloud icon). "Flood" is reserved for realized water.
- **The loud layers drew below the app's own quiet line.** Badges and
  striped ZCTA areas floored at 0.25 realized — deep inside the CLEAR band
  (green starts at 0.398). Summer predictor noise (PoP + heat + outlook,
  each capped, noisy-OR'd) sits ~0.3-0.5 across whole states, so the map
  painted stripes everywhere while claiming "normal stays quiet".
  `riskDisplayFloor` is now the clear/green boundary (walking mode 0.30);
  sub-floor weather still shows as the faint grid tint.
- **Unnamed things showed as mystery triangles.** A Special Weather
  Statement (sub-severe convective) fell to the generic triangle — now
  mapped to the storm icon. The remaining triangles are route-corridor
  risk markers (blended sample risk, no single named family); their tap
  popup explains the score honestly.

Also: park-and-ride. The transit access leg walked ANY distance — a
suburban start produced "walk 5 h 14 m to the Greyhound terminal" inside a
"6 h 47 m" option. Beyond a 45-minute walk the first leg is now DRIVE +
park (the traveller has a car at the start — it's a driving app), and the
same trip reads 1 h 53 m. The no-car rule still holds at the FAR end: the
last mile is always on foot.

## 15. The compendium cross-reference pass (2026-07-19)

A 260-technique optimization compendium was cross-referenced against the
codebase (12-domain audit incl. disassembly of the release build): 43
followed, 30 partial, 29 opportunities, none high-impact. What landed:

- **Launch path**: the 4 loop-invariant sin/cos hoisted out of the 33k-zip
  rescore (byte-identical); the risk bundle now ships as FRB1 binary
  (bundle-frb.rs; bit-exact doubles proven against JSONDecoder output on
  all 33,300 entries by an independent parser) — zero JSON parse at launch
  and 2.85MB JSON out of Resources.
- **Memory**: places shards are mapped (.mappedIfSafe), not copied — clean
  evictable pages instead of jetsam-bait; FPS1 offset tables are u32;
  record decode peeks the fixed prefix before paying for strings.
- **Network waste**: in-flight coalescing added to the 3 fetchers missing
  it; 10 wipe-all cache evictions became drop-oldest-half; fuel prices got
  a TTL.
- **Engines**: RAPTOR rounds now copy into preallocated flat rows
  (split_at_mut) with hoisted per-round scratch and a per-scan target
  bound; CH witness searches share an epoch-stamped scratch (O(settled)
  resets, not O(n) INF-fills — the flows-core suite itself dropped
  34s→22s). Both gated by their differential oracles.
- **Trainer** (legal there, banned in flows-core): mul_add + two-way
  accumulators, the wmean division hoisted (~460M fdiv → 1.16M), dynamic
  chunk self-scheduling for P/E-core balance with deterministic reduce
  order.
- **THE ASM RETIRED.** The bench bake-off (bin/bench.rs) measured the hand
  AArch64 polyline kernel at 3.20 ns/byte vs 2.59 for the portable
  raw-pointer body — rustc out-scheduled it. Per our own doctrine (asm
  must beat the compiler; dead fast-variants get deleted) the kernel is
  gone; the raw-pointer body ships on all targets, pinned to the safe
  oracle by the same equivalence tests. FLOWS now ships two languages.
  The lesson: the previous bake-off compared asm only against Vec::push —
  the win was never the assembly, it was avoiding the push.
- **Hygiene**: QoS on stragglers (pollers, persistence, the 50Hz motion
  stream off main), the red-alert timer gated + tolerant, signposts on the
  heavy phases, iOS device slice now builds at target-cpu=apple-a12 (the
  deployment floor), the broken R-era corpse deleted (global.R etc.
  sourced a directory removed in c8a903e), and r.yml — CI that could
  never pass — replaced by a real clippy -D warnings + dual-suite gate.

Deferred with reasons recorded in the audit artifact: Swift grid
flattening + ZipEntry hot/cold split (medium, has brute-force equality
tests to gate it), CH up-graph CSR flatten, RAPTOR cross-query scratch
(NA-scale), PGO, the god-file split.

## The review pass: what a promise costs when nothing enforces it

Four findings from the September 2026 review, and the shape they share.

**A promise with no mechanism behind it decays silently.** "Erase
everything FLOWS has learned" reached five behaviour stores and missed
four — the breadcrumb trail, the cached offline corridors, and the
learned traffic-delay and road-efficiency models. Those four were the
most sensitive data the app holds, being a record of where the driver
physically went, and they were plain-text JSON with no eraser at all.
Nothing broke; nothing warned. Each was added later than the button,
and adding a store simply did not require touching the eraser.

Worse, the previous commit's own message claimed each store shredded
its plaintext. That was true of the five that were wired and false of
the four that were not, and it was written without checking. **Do not
assert in a commit message what you have not read.** A confident
sentence about coverage is exactly the thing a reviewer will trust
instead of re-deriving.

The general rule: when a user-facing promise spans a growing set of
files, the set must be a list the code walks, not a series of call
sites a future author is expected to remember.

**A variable named for an intention is not that intention.** The fuel
scan collected stations inside a straight-line radius, stored them as
`ahead`, and carried a comment saying stations behind were excluded.
Nothing checked direction. A driver with 50 miles of range whose only
nearby pumps were already passed was told options remained, and the
last-chance warning — whose entire job is to fire before reachable
options run out — stayed quiet. The name and the comment were the only
things making it look correct, and both were free to write.

**didSet does not fire for a restored value.** A persisted
`towingActive` came back true at launch with every towing route filter
off, because the side effects lived in the property observer and
restoration writes the backing store. A driver who quit while towing
relaunched into an app that knew it was towing and would still route
under a low bridge. Launch is not a write; anything a setter does for
correctness has to be done again at init.

**A merge can hand one feature another feature's state.** AM/FM plays
through the weather radio's player but is not in its channel list, so
auto-tune read a music station as "playing something unplaceable" and
the tuning rule — correct in isolation, for a relay with no published
coordinates — yielded to the nearest transmitter. Music was swapped for
NOAA on the next GPS fix. Neither piece was wrong alone. The bug lived
in the assumption that everything in the player was a weather channel.

**On the review itself.** The first attempt fanned out 382 agents and
died on a session limit with 18 complete, and its "refuted" count was
an artifact of findings that had received zero votes — a number that
looked like a result and was not one. The four fixes above came from
reading the code by hand. Scale bought a bigger candidate list, not
more confirmed bugs; verification is the expensive half and it does not
parallelize away.
