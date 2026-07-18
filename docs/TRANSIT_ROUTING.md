<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS Transit Routing — Architecture

Real, multimodal public-transit routing **in FLOWS** — multi-hop intercity with
transfers (Miami → Atlanta → Chicago), local subway/bus legs on real networks,
and mixed-mode Pareto-optimal itineraries — computed on-device by an owned Rust
engine. This will replace the MapKit stopgap (real walk legs + a road-corridor
ride proxy — see the shipped-stopgap section below), which cannot do transfers,
local routing, or optimization because **MapKit gives third-party apps no
transit routing at all**.

Design chosen by a multi-proposal design panel (memory-first / correctness-first /
shippable-first) synthesized against the project's hard constraints.

## Status (2026-07)

**Phase 0 is built and tested. Phase 1's feed→`.ftt` pipeline is DONE — real
GTFS feeds now convert to `.ftt` shards and plan identically after reload;
Swift wiring is the next gate.** What runs today:

- **GTFS → `.ftt` pipeline (DONE, 2026-07-10):**
  - `rust/flows-core/src/transit/ftt.rs` — `.ftt` v1 writer/reader (pure std):
    64-B header (`FTT1` magic, version, counts, body length, **fnv1a-64 body
    hash** — a corrupt/truncated/mismatched shard is refused, never trusted)
    + exactly the flat CSR arrays `Timetable` holds, little-endian, 4-byte
    aligned. v1 reads sequentially into owned arrays (sub-ms for metro-size
    shards); the layout is mmap-ready without a format change.
  - `rust/flows-core/src/transit/gtfs.rs` — GTFS-Schedule parser (pure std):
    owned streaming RFC-4180 CSV (quoted commas/quotes/newlines, CRLF, BOM,
    missing optional columns), `H:MM:SS`/`HH:MM:SS` times **past 24:00:00**,
    blank non-timepoint times linearly interpolated, `calendar.txt` and/or
    `calendar_dates.txt` (either model alone) filtered to **one service
    date**, optional `transfers.txt` → footpaths, optional `frequencies.txt`
    expanded to concrete departures, GTFS `route_type` (base + extended) →
    engine mode byte. The load-bearing RAPTOR derivation is in and tested:
    trips grouped by (GTFS route, identical ordered stop sequence), sorted by
    departure, and **overtaking trips split into separate engine routes** so
    `earliest_trip`'s binary-search invariant holds.
  - `gtfs-ftt` CLI (`rust/flows-core/src/bin/gtfs-ftt.rs` — a cargo
    auto-discovered bin; it links the rlib and leaves the staticlib Swift
    links untouched): `gtfs-ftt <gtfs-dir> <out.ftt> [YYYYMMDD] [--verify]
    [--plan FROM TO HH:MM]`. The converter **never reads the system clock**
    (default date = first weekday the calendar covers with service); wrappers
    pass "today" in. `--verify` reloads the written shard, asserts a
    byte-identical re-encode, and asserts RAPTOR plans are **identical on
    original vs reloaded**.
  - Scripts: `scripts/fetch_gtfs.sh <url> <name>` (polite curl + unzip into
    `data/transit/<name>/`, gitignored — feed licenses vary) and
    `scripts/build_ftt.sh <name> [YYYYMMDD]` (computes today, runs the
    converter with `--verify`).
  - **Proven on a real feed** (Madison Metro, 2026-07-10 service day): 17 MB
    `stop_times.txt` → parse+build 0.33 s → **0.57 MB `madison.ftt`** (1,684
    stops, 96 engine routes, 1,411 trips, 61,478 stop-events ≈ 9 B/event
    incl. header) → reload 1 ms → real itineraries (e.g. Airport → Epic
    transfer → Verona, 1 transfer) in **~0.1 ms** per Pareto query, identical
    on original vs reloaded.
  - Note on placement: the GTFS parser lives inside `flows-core::transit` for
    one test suite and shared types, but it is **reachable only from the
    `gtfs-ftt` bin** — no FFI entry references it, so the app's dead-stripped
    static link never carries GTFS-format code; `.ftt` stays the only
    on-device format (the planned separate `flows-transit-build` crate was
    consolidated the same way Phase 0 consolidated `timetable`/`journey`).

- **Engine core (Rust, shipped in `flows-core`):** the in-memory CSR timetable +
  `TimetableBuilder` (`rust/flows-core/src/transit/mod.rs` — `StopEvent`/`Stop`/
  `Footpath`/`Timetable`, `earliest_trip` is a per-route binary search over
  pre-sorted non-overtaking trips) and bicriteria RAPTOR with journey
  reconstruction (`transit/raptor.rs` — `plan()` returns the (arrival, transfers)
  Pareto frontier ordered by increasing transfers; `earliest_arrival()` is the
  unbounded-transfer optimum). The **correctness gate is in and passing**:
  `correctness_gate_matches_reference_dijkstra` asserts RAPTOR earliest arrival
  equals an independent time-dependent label-setting Dijkstra oracle over the
  same randomized timetables — the `ch.rs`-vs-Dijkstra discipline applied to
  transit. 8 `#[test]`s in `raptor.rs` plus FFI-level tests in `ffi.rs`.
- **FFI (shipped, ahead of the phased plan):** `flows_transit_plan` in
  `rust/flows-core/src/ffi.rs` — `catch_unwind`-wrapped, two-pass sizing
  (`out_counts = [n_journeys, n_legs]` on the NULL pass), flat `FfiJourney`
  (`first_leg, n_legs, arrival, n_transfers, walk_secs`) + `FfiLeg`
  (`kind, mode, from_stop, to_stop, dep, arr, route, trip`) marshalling, Swift
  owns all buffers. Note the shipped surface takes the **timetable as flat
  arrays per call** (no persistent handle yet); the handle-based
  `open/close/scope` surface below is the Phase-1+ target once `.ftt` shards
  exist. `flows_transit_selftest` builds a canonical two-leg transfer timetable
  internally, runs RAPTOR, and returns 1500 — and
  `FlowsCore.transitSelfTest()` (`apple/FLOWS/Sources/Core/FlowsCore.swift`)
  dlsym-resolves it, proving the compiled RAPTOR engine links and executes
  on-device (the transit analog of the polyline decoder's linkage check).
- **Not yet built:** `backbone.ftt` (Amtrak + VIA merge — a multi-feed run of
  the now-working pipeline + cross-feed timezone normalization + stitching),
  `manifest.ftm`, the mmap zero-copy reader, and the **Swift wiring** of
  `.ftt`-loaded journeys into `TransitItinerary` (the next gate: a
  handle-based `flows_transit_open`/`plan` FFI over a bundled shard). Until
  that lands, **the app's transit UX is the MapKit stopgap — now substantially
  upgraded** (next section) — and the engine runs on-device only via the
  self-test.

## The shipped stopgap: MapKit itineraries, in FLOWS (superseded-by-design, still current UX)

The original stopgap (one nearest-station lookup + a Maps handoff) is gone. What
ships now keeps everything **in FLOWS** — no Apple Maps handoff — while honestly
labelling what it can't know without GTFS:

- **Full multi-leg itineraries** (`apple/FLOWS/Sources/Core/TransitItinerary.swift`,
  built by `computeTransit(rail:)` in `apple/FLOWS/Sources/UI/RouteChoicesView.swift`):
  walk to the boarding station → intercity/local RIDE → **walk from the arrival
  station** (the traveller doesn't have their car at the far end). WALK legs are
  real MapKit pedestrian routes with step instructions; the RIDE leg is drawn
  along the real ground corridor between stations (MapKit road geometry, straight
  connector only if unroutable — `rideGeometryIsReal` gates the claim) and flagged
  `rideGeometryIsApproximate` until GTFS supplies true rail shapes.
- **Honest, mode-differentiated timing:** `TransitPlanning.rideDuration` scales a
  measured MapKit drive time by a per-mode door-to-door overhead
  (`rideMultiplier`: Amtrak 1.45 / Greyhound 1.35 / local rail 1.30 / bus 2.0),
  falling back to conservative effective speeds (`fallbackMPH`, kept monotonic
  with the multipliers so mode ordering never flips) — labelled an estimate until
  GTFS lands.
- **Rail + bus multi-select cards:** `RouteChoicesView.TransitOption` keyed by
  rail/bus — both cards coexist, each carries **its own itinerary**; tapping a
  card draws *its* legs on the map (`activeTransitModes` set, latest-computed
  wins, stale async results are dropped by generation check).
- **Nearest-Amtrak recommendation:** when no local rail exists, the card still
  helps — it finds the closest rail station within intercity range and recommends
  it by name and distance ("No local rail nearby. Closest train: …, N mi away").
- **Exact ticket links, not a Maps handoff:** `TransitTickets.ticket` puts the
  precise ride (board → alight) on the card with the carrier's booking page
  (Amtrak → amtrak.com/tickets, Greyhound → greyhound.com); local transit links
  the boarding station/agency URL when MapKit knows it, else honestly nil (label
  still names the ride). Fare estimates via `TransitFares`
  (`apple/FLOWS/Sources/Core/Mobility.swift`): local bus ~$2.25 / rail ~$2.75
  flat, Amtrak ≈ $0.15/mi (min $15), Greyhound per-mile.

### Ticketing landscape (why deep links, not booked fares)

There is no free programmatic path to real fares/booking today, so the cards
deep-link rather than quote live prices:

- **Amtrak has no free public API.** Programmatic fares/booking go through GDS
  channels or accredited-travel-agency agreements; the practical third-party
  routes are OTA affiliate programs (**Wanderu**, **Busbud**) that pay commission
  on referred bookings.
- **Greyhound is a Flix company** (acquired 2021, and it exited Canada that
  year — the station search special-cases this); its affiliate/ticketing channel
  is the **Flix affiliate program**.
- Local agencies mostly have no purchasable web fare at all (on-board /
  agency-app), which is why the local card links the station page or shows an
  honest nil.

An affiliate integration (Wanderu/Busbud/Flix) is a plausible later revenue +
live-fare upgrade; it changes the ticket URL and label, nothing in the engine.

## The one binding constraint: device RAM

Full-NA GTFS for a single service day is ~300M `stop_times` ≈ **2.4 GB raw**
(~0.96 GB compressed). An older iPhone's per-process jetsam budget is ~900 MB on
a 3 GB iPhone SE (2nd/3rd gen), and exceeding it triggers **instant silent
termination**. So North America can **never** be held resident. Every decision
below serves the target: transit engine resident set **≤ ~50 MB**, coexisting
with MapKit tiles + weather/hazard layers + the road CH.

`resident_bytes ≈ 8 × Σ(resident stop-events) + footpaths(~8 B) + stops(~16 B)`
→ the whole budget reduces to the stop-events section, minimized hardest.

## Algorithm: RAPTOR (frequency-compressed FRAPTOR)

**RAPTOR** — Round-Based Public Transit Router (Delling/Pajor/Werneck) — chosen
over CSA and Transfer-Patterns:

- **Preprocessing-free at query time** → later GTFS-RT delay/cancellation edits
  are just array tweaks, no rebuild (realtime-ready).
- **Round _k_ = _k-1_ transfers**, so the time-vs-transfers Pareto frontier falls
  out for free, and multi-hop intercity works with no special-casing.
- **Local + intercity in ONE merged timetable** — a query rides an Amtrak route,
  transfers at a station that is also a local stop, then rides local rounds.
- **Multi-criteria** via McRAPTOR Pareto bags (time / transfers / walking / fare).
- **Pure array-walking**, no priority queue, no external crate — a perfect fit for
  `flows-core`'s pure-std / deterministic / own-your-tools rules.

Anchor: the entire London all-modes network (20,843 stops, 5.13M departure events)
is ~45 MB in the 8-B/stop-event layout and answers full Pareto queries in **5.4 ms**
single-core. Per-query work is proportional to the **corridor**, not the resident
union — the property that makes region-scoping pay off.

CSA is kept only as a documented drop-in fallback over the same format for a
single pathologically large metro. Transfer-Patterns is rejected: >3,000 CPU-hours
NA preprocessing and a ~30 GB index violate the determinism and on-device budget.
(`ch.rs` Contraction Hierarchies stays scoped to the **road** graph.)

**Determinism:** all times are `u32` seconds (no float clock), routes scanned in
ascending id, trips pre-sorted non-overtaking, footpaths ascending, ties broken by
a total order (arrival, transfers, walk, trip-id) — bit-exact across devices.
**Correctness gate:** a test asserts the time-only projection equals a
time-dependent Dijkstra reference (the same `ch.rs`-vs-Dijkstra discipline), plus
golden-hash tests on known OD pairs.

## Region-scoping: two-tier resident model

The load-bearing decision — never hold all of NA at once.

- **Tier 1 — national intercity backbone, ALWAYS resident.** Amtrak + VIA Rail +
  intercity coach merged into `backbone.ftt`: ~40k stop-events ≈ **<1 MB**.
  Bundled, mmap'd at launch, never evicted. Any coast-to-coast corridor is
  plannable at the intercity layer even before a metro loads — and this Tier-1
  slice alone is the first shippable release.
- **Tier 2 — metro local networks, LAZY-LOADED + EVICTABLE.** One `.ftt` per metro
  (subway + bus + commuter rail). Only the 2–3 shards a corridor's endpoints touch
  are mapped; a Chicago-scale metro ≈ 13 MB compressed. Working set = backbone +
  ≤3 endpoint metros ≈ **~45 MB**. LRU with a device-tiered cap (`AdaptiveTuning`:
  2 low / 3 standard / 4 high); the backbone is never evicted.

**mmap-in-place, not heap-read:** a mapped-but-cold shard costs ~0 RSS until pages
are faulted, and clean file-backed pages are reclaimable under pressure — turning
the timetable from a jetsam liability into reclaimable pages.

**Cross-region stitching** (the correctness crux): an intercity terminal that is
also a local stop (e.g. Chicago Union Station in both the Amtrak backbone and the
CTA/Metra shard) is emitted as a stop in **both** shards, joined by an explicit
inter-shard footpath carrying the real minimum change time. Shard-local dense ids
are namespaced (high bits = shard id); at load the merge resolves twin stops by a
stable (lat, lon, name) key. These stitch edges are the only cross-shard edges and
are verified against ground-truth OD pairs.

## Data: the owned `.ftt` format + offline builder

Zero GTFS-format code ships on-device. An **offline** builder is the only writer;
`flows-core` mmaps and casts aligned sections to typed slices with no parse and no
allocation — the CSR discipline from `routing.rs::CsrGraph`.

**`.ftt` (FLOWS Transit Timetable)** — one versioned, little-endian, page-aligned,
mmap-in-place binary per shard:

- **HEADER** (64-B aligned): magic `FTT1`, format_version, word-size canary,
  shard_id, service_day tag, counts, section table (offset+len per section),
  fnv1a-64 body hash (validated on mmap — a corrupt shard is refused, never trusted).
- **STOPS**: `lat i32` / `lon i32` (1e6 fixed-point, half the size of f64),
  `name_offset u32`, `n_routes_at_stop u16`, `first_routeref u32`.
- **ROUTES** (RAPTOR routes = identical-stop-sequence groups), CSR: route→stop-list,
  route→trip-list, per-route `mode u8` (rail|subway|bus|coach|commuter), name, agency.
- **STOPEVENTS** (memory-dominant): per (trip, stop) `(arr u32, dep u32)` seconds
  since service midnight, trip-major within each route (8 B/event). A parallel
  **FREQ** section stores evenly-spaced trip families as `(first_dep, headway,
  count, span)`, expanded on the fly → toward ~4 B/event effective.
- **FOOTPATHS** (CSR): `from → (to u32, secs u16)`, bounded ≤400 m and transitively
  reduced so the set stays near-linear (no quadratic transfer-graph blow-up).
- **STITCHES**: `(backbone_stop, metro_stop, min_change_secs)` cross-shard joins.
- **STRING BLOB**: NUL-terminated names by offset, kept out of the hot arrays.

**`manifest.ftm`** (small, always resident): per-shard bbox / centroid / agency /
service_day / size / hash / feed version / valid_until / download URL, plus the
global stitch table and the bbox selection index. Swift reads it to pick, verify,
and lazily fetch shards.

**Offline builder** — `flows-transit-build`, a **separate** bin crate in the `rust/`
workspace, pure-std, same zero-crate rule, **never linked into the app**. Per feed:
owned DEFLATE-inflate of the GTFS `.zip` → owned RFC-4180 CSV parse → service-day
expansion → RAPTOR route grouping (non-overtaking split) → FRAPTOR frequency
compression → bounded transitively-reduced footpaths → id interning → serialize one
`.ftt` per shard + `manifest.ftm`. Deterministic: a pure function of (feed bytes,
service-day selector, config) with a recorded input SHA256, gated by a CI
golden-hash check. Only **data** is ever downloaded — never a tool or library — so
the zero-crate attack-surface rule holds.

## Feed manifest & rollout

One checked-in `data/transit/feeds.toml` (read by the builder only) drives an
incremental rollout; the builder refuses any shard whose download SHA doesn't match.

- **Tier 1 (first release):** Amtrak GTFS + VIA Rail GTFS (+ intercity coach where a
  clean feed exists) → one `backbone.ftt`.
- **Tier 2 (added one at a time, NO code change):** major-metro GTFS from the
  Mobility Database catalog — NYC MTA, CTA/Metra, WMATA, MBTA, BART/Muni, SEPTA,
  Metrolinx/GO, STM Montréal, LA Metro. Each metro = one `feeds.toml` row + a
  builder run + dropping the new `.ftt` into the bundle/container.
- **Realtime (later):** GTFS-RT `.pb` (MTA + BART keyless; MBTA/WMATA/511-Bay-Area/
  Metra free-key) applied as FRAPTOR array deltas at query time — needs an owned
  protobuf-subset decoder; additive.

The Mobility Database catalog ([sources.csv](https://bit.ly/catalogs-csv), from
[github.com/MobilityData/mobility-database-catalogs](https://github.com/MobilityData/mobility-database-catalogs))
is the ingest index: filter its CSV by `country_code in {US, CA}` for direct
download URLs + normalized license metadata.

**Exact feed counts** (measured 2026-07-06 against the catalog's 3,339-row
`sources.csv`, active feeds only): **US = 829 GTFS-Schedule feeds (820 keyless),
CA = 108 (all keyless), MX = 7.** Catalog-wide: 2,380 GTFS-Schedule + 959
GTFS-RT rows (RT rows are country-tagged only via their `static_reference`, so
they don't filter by country directly). The advertised "6,000+ global" figure
additionally counts GBFS (bikeshare) and other types absent from this GTFS
`sources.csv` — so 829 US / 108 CA is the real GTFS-Schedule answer, not the
earlier ~1–2k estimate.

**Verified feed sizes** (downloaded + measured 2026-07-06 — confirms the shard
memory model; every metro here is far below the NYC-bus ~2 GB outlier, and even
the largest compresses well under the ~13–30 MB shard target):

| Agency | Zip | `stop_times` rows | trips | stops |
|---|---|---|---|---|
| MBTA (Boston) | 24.7 MB | 3,348,811 | 122,191 | 10,308 |
| SEPTA bus | 19.4 MB | 2,064,858 | 34,803 | 14,223 |
| SEPTA rail | 0.7 MB | 35,092 | 2,308 | 156 |
| STM Montréal | 57.1 MB | 7,151,705 | 203,056 | 9,188 |
| LA Metro bus | 21.2 MB | 2,106,178 | 33,614 | 11,891 |
| LA Metro rail | 1.2 MB | 144,387 | 6,413 | 463 |
| GO Transit (Metrolinx) | 19.0 MB | 1,797,120 | 105,296 | 888 |

STM is the heaviest at 7.15M stop-events ≈ 57 MB raw → ~28 MB compressed → still
one corridor-endpoint metro well inside the ~45 MB working-set budget. (GO Transit
lives at the Metrolinx open-data URL `assets.metrolinx.com/raw/upload/Documents/Metrolinx/Open Data/GO-GTFS.zip`,
not the catalog's stale row.)

**Licensing is per-feed and genuinely mixed — NOT uniformly open** (verified feed
research). GTFS carries no standard machine-readable `license` field, so the license
lives in the agency portal / Mobility Database metadata and must be tracked in
`feeds.toml` per feed, never read from the zip. Redistributing derived `.ftt` shards
in a shipped app is fine for a large share (MTA, STM Montréal `CC BY 4.0`, GO/Metrolinx
`OGL-Ontario`, VIA `OGL-Canada`, BART) — generally with attribution. But a meaningful
minority sit behind **click-through license agreements with varying terms**: CTA
(purpose-limited + revocable), Metra (must **rehost**, not hotlink), MBTA/SEPTA/SFMTA
(license-gated), WMATA (API key required even for static GTFS). So there is **no single
license covering all NA feeds** — FLOWS needs a per-feed license ledger + attribution
manifest, and a **lawyer-reviewed allowlist** keyed off the Mobility Database license
fields before shipping any feed's shards. This is a compliance gate on the data
rollout, not a technical one.

Refresh runs on the existing cron cadence: conditional-GET each feed, rebuild only
shards whose input SHA changed, bump version/valid_until/hash. A shard past
valid_until refreshes in the background but stays usable (stale-but-serving); a
hash-mismatched shard is refused on mmap.

### Builder ingest constraints (from feed research)

- **Stream large feeds.** NYC MTA publishes bus as **five borough feeds**; the
  concatenated `stop_times.txt` is **~2 GB / 30M+ rows** (Brooklyn alone ~700 MB),
  reducible to ~6M rows after de-duplication. The owned inflate + CSV must **stream**,
  never load a whole member into RAM, or the builder dies on NYC. Most other big-city
  `stop_times` are single-digit to low-tens of MB; Amtrak ~4.3 MB zip, VIA ~0.9 MB.
- **RAPTOR routes ≠ GTFS `route_id`.** Partition trips by identical ordered
  stop-sequence, sort by departure, split overtaking trips — the load-bearing
  derivation the runtime depends on.
- **Handle both calendar models.** `calendar.txt` weekly pattern AND
  `calendar_dates.txt`-only feeds (NYC subway is calendar_dates-only) → one canonical
  service day.
- **Expand `frequencies.txt`** (headway-based service) into concrete departures before
  the FRAPTOR even-headway re-compression.
- **Agency timezone is load-bearing.** GTFS times are local; a cross-timezone corridor
  (Amtrak spans ET→CT→MT→PT) must normalize to a common epoch at the stitch, or arrival
  math is off by hours.
- **`shapes.txt` is display-only** — not needed for routing and often the 2nd-largest
  file. Drop it from the hot routing arrays; keep a downsampled copy only for drawing
  the ride leg (or omit and draw station-to-station until it lands).

## FFI (C-ABI, matching `ffi.rs` conventions)

> **Partially shipped / partially target.** `flows_transit_plan` +
> `flows_transit_selftest` exist today (flat-array timetable per call — see
> Status above). The handle-based `open`/`close`/`scope`/`stop_name`/`leg_shape`
> surface below is the design for the mmap'd-shard world and lands with `.ftt`.

Swift owns all output buffers; Rust allocates nothing across the boundary; every
entry point is `catch_unwind`-wrapped (a panic must never cross `extern "C"`);
two-pass sizing (null out-buffer returns the needed count, like
`flows_polyline_decode`); error sentinels, never aborts.

- `flows_transit_open(shard_paths, n, out_handle) -> i32` — mmap backbone + shards,
  resolve twin-stop joins, return an opaque `*TransitEngine`.
- `flows_transit_close(handle)` — munmap and drop.
- `flows_transit_scope(handle, src_lat, src_lon, dst_lat, dst_lon, out_ids, cap)` —
  which metro shards a corridor needs (so Swift can lazy-fetch/open them first).
- `flows_transit_plan(handle, src, dst, depart_epoch, max_walk_m, criteria_mask,
  out_journeys, cap) -> i64` — run RAPTOR, write up to `cap` Pareto journeys to a
  caller-owned flat buffer, return the total count (null/0 to size).
- `flows_transit_stop_name` / `flows_transit_leg_shape` — pull names and ride-leg
  shape points by id (shape reuses the lon-first f64-pair convention of
  `flows_polyline_decode`).

Flat marshalling (no nested allocation): `FfiJourney {n_legs, arrival, n_transfers,
walk_secs, legs_offset}` + a parallel `FfiLeg {kind, from_stop, to_stop, dep, arr,
route_id, n_shape_pts}`. Each `FfiJourney` → one `TransitItinerary`; each `FfiLeg` →
one `TransitLeg` (walk/ride/**transfer**); the Pareto set → the route-choice list
`RouteChoicesView` already renders.

## Rust modules (`flows-core::transit`)

As built, the Phase-0 code consolidated slightly: the timetable lives in
`transit` itself (`transit/mod.rs`) rather than a `timetable` submodule, and
journey reconstruction + the FFI structs live inside `transit::raptor` / `ffi.rs`
rather than a separate `transit::journey`. The planned split below still holds
for the pieces not yet written.

- `transit` (mod.rs) — **built**: the in-memory CSR timetable + builder (Phase 0);
  the structs are field-width-matched to the `.ftt` sections on purpose.
- `transit::raptor` — **built**: the RAPTOR round loop (bicriteria: arrival +
  transfers) with bounded-footpath transfers, journey reconstruction (`plan`,
  `earliest_arrival`), and the Dijkstra correctness gate.
- `transit::ftt` — **built**: `.ftt` v1 `write_ftt`/`read_ftt` (header +
  fnv1a-64 hash validation + full bounds/CSR-invariant checks; sequential v1
  reader, mmap-ready layout).
- `transit::gtfs` — **built** (offline-only; only the `gtfs-ftt` bin references
  it): streaming CSV, calendar/service-date expansion, frequencies expansion,
  transfers→footpaths, and the overtaking-split RAPTOR route derivation
  (`load_gtfs(dir, date) -> GtfsLoad { Timetable, names, stats }`).
- `transit::mcraptor` — Pareto bag labels for the walking (then fare) axes;
  feature-gated so bicriteria ships first with zero bag overhead.
- `transit::engine` — the opaque `TransitEngine`: holds mapped shards, resolves
  twin-stop joins into one logical timetable, does nearest-boardable-stop resolution
  (via `distance.rs`), owns the query entry.
- `transit::csa` — documented CSA fallback over the same format.
- `flows-core::ffi` (extend) — the `flows_transit_*` surface above.

## Phased build plan

- **Phase 0 — engine core — ✅ DONE (pure Rust, no device, no feeds):** the
  in-memory CSR timetable + builder, bicriteria RAPTOR + journey reconstruction, and
  the **correctness gate** (RAPTOR earliest-arrival == time-dependent Dijkstra on
  random timetables) — all in `flows-core::transit`, `cargo test`-verified. The
  `flows_transit_plan`/`flows_transit_selftest` FFI also landed early, with the
  on-device linkage check in `FlowsCore.transitSelfTest()`. _(From Phase 0's
  tail, owned CSV + the `.ftt` writer/reader landed with Phase 1 below; owned
  `inflate` stays queued — `unzip` is build-host tooling for now.)_
- **Phase 1 — first vertical slice — feed→`.ftt` ✅ DONE (2026-07-10), Swift wiring NEXT:**
  the GTFS parser (`transit::gtfs`), the `.ftt` v1 writer/reader with hash
  validation (`transit::ftt`), the `gtfs-ftt` converter CLI, and
  `scripts/fetch_gtfs.sh`/`scripts/build_ftt.sh` — verified end-to-end on the
  real Madison Metro feed (round-trip byte-identical, plans identical on
  original vs reloaded; see Status). **Usage:**
  `scripts/fetch_gtfs.sh <feed-url> <name>` then `scripts/build_ftt.sh <name>
  [YYYYMMDD]` → `data/transit/<name>.ftt`. Remaining for the slice: run it on
  Amtrak + VIA → `backbone.ftt` + `manifest.ftm` (cross-feed timezone
  normalization at the stitch); wire the handle-based `flows_transit_*` FFI +
  the Swift loader; extend `TransitLeg` with `case transfer`; ship real
  intercity-with-transfers, retiring the MapKit stopgap. Golden-hash the
  backbone build and known OD pairs.
- **Phase 2 — region-scoping + first metros:** shard union + stitch + LRU eviction +
  `flows_transit_scope`; import 2–3 top metros; validate cross-region stitching.
  Each further metro is a `feeds.toml` row = pure data-ops.
- **Phase 3 — multi-criteria:** turn on the McRAPTOR walk axis, then fare.
- **Phase 4 — realtime:** owned GTFS-RT `.pb` subset decoder + `flows_transit_apply_rt`
  array deltas. Additive — no engine rewrite.

## Risks (from the design panel)

- **Feed-scale surprise:** NYC MTA bus `stop_times` ≈ 2 GB / >30M records; naive
  full-NYC raw (~240 MB) + MapKit tiles approaches the ceiling. → always
  FRAPTOR-compress, split NYC into borough/mode sub-shards, cap resident metros to
  the corridor's real endpoints.
- **Footpath blow-up:** a large connected footpath component is quadratic. → bound
  the transfer radius (≤400 m) and transitively reduce in the builder.
- **Cross-region stitching:** twin-stop joins are where multi-leg plans silently go
  wrong. → model each terminal in both shards + a real-min-change footpath; verify
  against ground-truth OD pairs.
- **Owned-pipeline breadth:** inflate + CSV + calendar + FRAPTOR + serialization
  under the zero-crate rule. → offline-only, each piece pinned to known-answer
  fixtures (the polyline-decoder discipline); the device never sees any of it.
- **Determinism across refreshes:** a feed refresh could silently change journeys.
  → builder is a pure function of recorded inputs; shards carry version + service_day;
  the runtime refuses hash-mismatched shards.
