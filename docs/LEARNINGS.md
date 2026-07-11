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
