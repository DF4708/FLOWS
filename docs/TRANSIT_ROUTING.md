<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
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

## Status (2026-09-22)

**Phase 0 is built and tested. Phase 1's feed→shard pipeline is DONE — real
GTFS feeds convert to a shard pair and plan identically after reload; Swift
wiring is the next gate.**

> **Correction (2026-09-22):** an earlier revision of this document described a
> C-ABI `flows_transit_*` FFI in `rust/flows-core/src/ffi.rs` as shipped. That
> file no longer exists: the whole C-ABI layer was deleted when the project
> moved to **swift-bridge**, and `flows_transit_plan` was removed along with it
> because nothing called it (see the note in `rust/flows-core/src/lib.rs`). The
> FFI section below is kept as a record of the shape that was tried, but it is
> **not the plan** — the transit surface will cross the bridge the way every
> other FLOWS module does: a `#[swift_bridge::bridge]` module in
> `rust/flows-bridge`, listed in that crate's `build.rs` `BRIDGES`, behind a
> Swift facade. There is no on-device linkage self-test any more either.

Two things landed on 2026-09-22 that the phase plan had deferred:

- **The shard is a PAIR.** `<name>.ftt` holds only what RAPTOR reads (positions
  and times — every byte resident during a query); `<name>.fts` holds what a
  rider reads (stop names, the operator's station codes, IANA timezones, the
  service date, and the feed's publication date). `transit/shard.rs` writes and
  opens both, and the `.fts` carries the `.ftt`'s fnv1a-64 body hash, so labels
  from one build can never be applied to another build's stop indices. The
  `.ftt` format itself did not change — it stays the tested, hashed v1.
- **Timezones travel with the shard**, because getting them wrong is the worst
  failure this feature has. Per the GTFS reference, **every** time in
  `stop_times.txt` is measured from midnight in the *agency's* zone no matter
  where the stop is. Amtrak publishes one agency zone (`America/New_York`) and
  four stop zones; the Coast Starlight's Seattle departure is stored as
  `12:55:00` and belongs on screen as 9:55 AM. So `.fts` stores the agency zone
  plus each stop's own zone, and the Rust side stays clock-free and
  tz-database-free: a query takes and returns seconds from service midnight,
  and **Swift** does `agency-midnight + seconds`, rendered in the stop's zone
  (Foundation has the tz database; Rust here does not).

What runs today:

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
    one test suite and shared types. An earlier revision noted that it was
    reachable only from the `gtfs-ftt` bin, so the app's dead-stripped static
    link never carried GTFS-format code. **That is deliberately no longer
    true**: agencies publish schedules as GTFS zips and nothing serves us
    pre-built shards, so the device parses the feed itself and writes its own
    pair. The parser ships. (The planned separate `flows-transit-build` crate
    was consolidated the same way Phase 0 consolidated `timetable`/`journey`.)

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
  transit. 8 `#[test]`s in `raptor.rs`.
- **The shard surface (`transit/shard.rs`, 2026-09-22):** `build()` (GTFS dir →
  `.ftt` + `.fts`), `write()` (same, from a load the caller already holds),
  `open()` (both files, refusing a mismatched or corrupt pair), plus the only
  two questions the app asks — `nearest_stops(lat, lon, max_m, limit)`, which
  skips stops no trip ever calls at, and `departures(from, to, depart_secs)`,
  which returns the Pareto set rendered with names, codes, zones and route
  labels. 7 `#[test]`s over a synthetic two-timezone feed.
- **Proved on the real Amtrak feed (2026-09-22):** the published GTFS
  (19.5 MB zip) builds to a **110 KB `.ftt` + 30 KB `.fts`** — 645 stops, 360
  engine routes, 594 trips, 5,569 stop-events — parsed in 0.16 s, written in
  0.03 s, reloaded byte-identically in 1 ms, with a Milwaukee → Chicago query
  answered in **0.06 ms** (Hiawatha Service, stored 07:15 → 08:57 Eastern,
  which is the 6:15 AM a Milwaukee rider actually catches).
- **Built 2026-09-22:** the device-side supply line (`TransitFeeds` fetches
  only the files the router reads — 1.58 MB of Amtrak's 19.48 MB — by byte
  range), the swift-bridge module over `shard.rs`, `TransitClock` for the
  agency-zone/noon-minus-12h rules, and real published times on the rail
  card, including connecting-coach legs named as buses.
- **Built 2026-09-29 — several feeds, one timetable:**
  `gtfs::load_gtfs_many(&[FeedInput { dir, shift_secs }], date)` merges feeds
  so one query can ride one operator's train and another's bus. Each feed's
  times are shifted into the FIRST feed's clock by a caller-supplied number
  of seconds (Swift computes it; Rust stays tz-free — put the easternmost feed
  first so shifts are never negative, and a trip a shift would push before
  midnight is dropped, never wrapped). Feeds never reference each other, so
  served stops from DIFFERENT feeds within `MAX_LINK_METERS` (400 m) get a
  footpath both ways at `LINK_WALK_MPS` (1.1 m/s, luggage pace) plus
  `LINK_BUFFER_SECS` (120 s). A feed's own stops keep exactly what its
  publisher said; a stop with no zone of its own keeps ITS operator's zone,
  not the merge's. A broken secondary feed is skipped and reported; the first
  feed's failure fails the load. `load_gtfs` is the one-feed case and was
  proved byte-identical on three real Amtrak service days. Proved live:
  Amtrak + LA Metro Rail, Bakersfield → Hollywood/Highland = Thruway coach to
  LA Union Station, a 5½-minute walk to the B/D platform, then the B Line.
- **Built 2026-09-29 — the Swift side of the merge:**
  `flows_transit_build_many` (U+001F-joined dirs + parallel `&[f64]` shifts;
  rows `info`/`built`/`linked`/`skipped`); `TransitClock.shift(from:into:
  serviceDate:)` — the gap between the two feeds' own GTFS day-starts, exact
  on clock-change days and for Phoenix (no DST); `TransitShard.build(feeds:)`;
  and `TransitFeeds.ready([Source])`, where the FIRST source must load and
  the rest are best effort. A city feed Rust skips (lapsed calendar,
  malformed files) is remembered as unusable for the day and the shard is
  rebuilt without it, so a shard's name, contents and credit line always
  agree. Amtrak alone keeps its old path and cache name byte for byte. (Until
  2026-09-30 the rail card merged Amtrak with the destination's city feeds
  through `TransitFeeds.sources(endingAt:)`; the combinations below replaced
  that with separate city legs — the merge now joins neighbouring CITY feeds
  for one leg.)
- **City buses ON (2026-09-29) — the owner's rule: every API-key-free feed
  by default.** `flows-train`'s `feeds-table` compiles MobilityData's current
  export (`files.mobilitydatabase.org/feeds_v2.csv`; the older bit.ly
  `sources.csv` lacks the Transitland- and NTD-sourced entries its own
  redirects point to) into `transit/feeds_table.rs`: **1,341 static feeds**
  (US 1,186 · CA 149 · MX 6). Kept: key-free, not deprecated, not redirected,
  a usable box; "inactive" feeds stay but rank last (the catalog stopped
  maintaining them — Milwaukee's is one — and the app already skips a lapsed
  or unreachable feed); the mirror link stands in when a publisher gives none.
  `transit::feeds::covering` ranks official → active → smallest box.
  - **Licences.** All are free to download. 204 state terms; read by hand,
    nine forbid commercial use without written permission (Kitsap, Whitehorse,
    STL Laval, RTC Washoe, RABA ×2, Metrobus St. John's, and two feeds served
    through BusOne). FLOWS earns referral fees, so those nine are marked
    `needs_permission` and never offered — kept in the table for the day
    permission is on file.
  - **Coverage of every state/province/territory capital and largest city**
    (146 places, GeoNames): US 83/84 (Frankfort KY missing), CA 15/18
    (Iqaluit has no transit; Whitehorse and St. John's are among the nine),
    MX 9/44 — and fewer in truth, since El Paso's and Yuma's boxes reach into
    Juárez and Mexicali without their buses doing so. Mexico publishes little
    open GTFS.
  - **Size limit — by memory, not file size (2026-09-30).** The first rule
    was a fixed 80 MB (phone) / 250 MB (Mac) of schedule text, because the
    app unpacked each file whole in memory: for Chicago's `stop_times.txt`
    that was the 54 MB download, a 367 MB buffer and a copy, so CTA — and
    with it every Chicago city leg — was refused on every phone and on the
    Mac. Measured, the timetable builder itself was never the problem: it
    streams the file and keeps one day, 75 MB peak for CTA (with every trip
    forced onto one day, 335 MB — 0.91 bytes per unpacked byte).

    Now nothing is unpacked in memory. `ThrottledNet.download` writes each
    member's byte range straight to disk (a bulk session: 10-minute limit,
    no HTTP cache, off in Low Data Mode); `TransitFeeds.keep` copies the
    member's data out of it a megabyte at a time and keeps a deflated member
    PACKED — `stop_times.txt.fz`: `FZ01`, the directory's CRC-32 and the
    unpacked length, then the archive's own DEFLATE bytes. Rust unpacks it as
    it reads (`transit::inflate`: pure-std RFC 1951 + CRC-32, fixed memory —
    64 KiB in, 32 KiB window, 256 KiB out — checked against the length and
    CRC at the end, so a cut or corrupted download is an error, never a
    shorter timetable). `open_member` reads either form; the newer wins.
    CTA on disk: 54 MB instead of 367.

    A feed is judged against memory: its worst case (the unpacked size of
    the files it reads) must fit in half of `os_proc_available_memory()` on
    iOS — a quarter of physical memory on a Mac or the simulator — and its
    download under 200 MB (1 GB Mac). The check runs on the archive's index
    before downloading and again, for the feeds of a merge together, before
    each day's build. The CSV reader now reuses one record buffer instead of a
    `String` per field: CTA's build went from 8.4 s to 4.7 s of CPU from
    plain files, 9.5 s from packed ones (unpacking costs about what system
    `unzip` does).

    Proved: timetables built from packed files are byte-identical to those
    from `unzip`'s output for Amtrak, MCTS, Metro Transit, the Metro
    Transit + MVTA merge and CTA; in the simulator the app downloaded CTA
    (its `stop_times.txt.fz` byte-identical to the member cut from the
    archive by hand), built CTA + Pace in about 20 s at +95 MB, and planned
    Wrigleyville → Midway on CTA 22, 36 and 62 and Pace 315.
    A HEAD request comes first: a host that will not serve byte ranges must
    send the WHOLE archive, so its length is checked before a byte arrives
    (60 MB phone / 250 MB Mac; that archive is still held in memory, and cut
    up without unpacking). In a sample of 21 hosts, 17 served ranges.
  - **Dead links.** Publisher links go stale — 2 of that 21 were 404s. Every
    feed in the table also carries MobilityData's mirror of its latest copy
    (`files.mobilitydatabase.org/<id>/latest.zip`, which serves ranges); a
    failed publisher fetch retries the mirror, except when the refusal was
    for size, since the mirror is the same feed. Proved live on Casco Bay
    Lines: publisher 404, mirror fetched, and the build then correctly
    refused a timetable that ended in June.
  - **Routing fixes found by running it live** (Chicago → UW-Milwaukee took
    3 changes, the last a one-stop ride, arriving 11:06): stops within one
    CITY feed are now walkable within 400 m (the first feed's stay as
    published, so Amtrak-only shards are unchanged); a station-to-city walk
    reaches 800 m; journeys cost arrival + 5 min per change; and the stop pair
    is chosen by the whole trip (access walk delays boarding, egress walk
    adds). Result: 1 change — the Hiawatha, a 10-minute walk, Route 30 —
    arriving 10:39.
- **Any mix of toggles is one trip (2026-09-30) — the owner's rule.** The
  Routes card has Drive | Walk and four toggles: train, bus, plane and (new)
  rental car. "Car, bus and train" means drive to the train and take the bus
  from the far station; "walk, bus and plane" means the city bus to the
  airport and from it — unless the rental car is on too, which is then picked
  up where the plane lands. `flows_core::trip_shape::shape` reads a selection
  and the trip's length and returns one shape, with a test over every one of
  the 63 selections (31 before the ship) at three distances:

  | Part | Rule |
  | --- | --- |
  | Main ride | plane when flying is worth it (≥ 100 mi), else Amtrak (train, > 60 mi), else Greyhound (bus, > 60 mi); none on a short trip |
  | Way there | Drive: walk if ≤ 45 min, else drive and park. Walk: the city's buses/trains when chosen and ≥ 5 min faster than walking, else walk (ride share past 45 min) |
  | Way from | rental car when on; else the city's buses/trains when chosen and ≥ 5 min faster; else walk (from an airport: walk, ride share, or rent/ride) |
  | Short trip | city buses/trains door to door on one card; a rental car alone is picked up near the start on its own card |
  | Plane too short | its card says why; the ground toggles make the trip |

  A train choice accepts the city's trains, a bus choice its buses. The
  planner holds to that with a **vehicle mask** (`transit::Mode::bit`,
  `TRAIN_VEHICLES`, `BUS_VEHICLES`; `raptor::plan_vehicles`,
  `Shard::board_vehicles`, `nearest_stops_vehicles`, and a mask argument on
  `flows_transit_departures`) — but not at any cost: another city vehicle
  takes a leg when none of the chosen ones can, or it is ≥ 15 min faster, and
  the card says so. Found live: MSP's link to downtown Minneapolis is the
  Blue Line light rail, and buses alone went by way of St. Paul.

  Each city leg is its own query on a shard of only the city feeds at its
  ends (`TransitFeeds.citySources`), and Amtrak is asked separately, from
  the station the rider is actually going to, for when they get there — so
  the mask never touches the connecting buses Amtrak runs as part of the
  train, and a 40-minute drive to the station is no longer charged as a
  7-hour walk. The legs carry stop coordinates (four new fields on each
  `leg` row) so a city ride is drawn stop to stop and walked to by MapKit;
  `TransitSchedule.joined` shows the whole trip's timetables as one clock
  door to door, every operator credited. The card appears at once with the
  walk, drive or rental, then again as the timetables answer; the ride leg
  takes the train's own time once Amtrak's timetable has it.

  Proved live in the simulator: Chicago → UW-Milwaukee by car, train and bus
  (drive to Union Station 18 min, Hiawatha 6:10–7:49, MCTS 12 and 66 to
  Hartford & Maryland 8:37); Chicago → Minneapolis on foot with bus and plane
  (Blue Line from MSP Terminal 2 with the note); the same with a rental car
  (counters 0.3–0.5 mi from MSP, each booked through the FAWN link); a short
  Milwaukee trip with bus and rental (Route 30 card, and a rental card from
  the nearest counter).

  Two things the run showed: CTA's timetable was over the old 80 MB limit, so
  a Chicago city leg fell back to walking or a ride share (fixed the same
  day — see Size limit above); and MapKit's rental search from one city about
  another returned the first city's counters, 340 miles off — now a hard
  search box (iOS 18/macOS 15) plus a 20-mile cutoff.
- **The ship (2026-09-30) — the owner's request: "a ship button that
  includes ferries and any other sea transport such as cruises."** Boats now
  have their own vehicle, `Mode::Ship` (byte 5; GTFS route_type 4, 1000–1099
  and 1200–1299). Before, they fell through to `Bus`: the Staten Island Ferry
  read "Bus" on a card and was boarded by riders who chose the bus.
  `ALL_VEHICLES` gained the bit; `SHIP_VEHICLES` is the ship's mask and
  `LAND_VEHICLES` (buses and trains) is what may stand in for a chosen bus or
  train — never a boat. The `.ftt` reader accepts byte 5; the format version
  is unchanged.

  | Selection | Trip |
  | --- | --- |
  | Ship (with anything but a plane worth taking) | the ferry is the main ride, at any distance — the water decides, not the miles |
  | Walk + bus + ship | the city bus to the terminal and from the far one, one card |
  | Car + ship | drive and park at the terminal (or drive aboard — the operator says); rent or ride from the far one |
  | Plane + ship, long trip | the plane is the ride; a ferry may carry an end |
  | No ferry joins the two places | the ship card says so, with a ferry search and the cruises from the nearest cruise terminal, and the rest of the selection is planned without it |

  Which feeds run boats: the catalog does not say, so
  `feeds::CityFeed::carries_ships` reads the operator's name (whole words:
  ferry, ferries, seabus, steamship, cruise, boats, water taxi, …; "Steamboat
  Springs Transit" and the "Corona Cruiser" are buses) plus `SHIP_SYSTEMS`,
  the city systems that run ferries under their own names (Kitsap Transit,
  King County Metro's water taxi, the MBTA, Golden Gate, TransLink's SeaBus,
  Halifax, Casco Bay Lines, the Catalina Flyer). `feeds::ships_near` reaches
  40 km past a feed's box, because a terminal is often outside the town's;
  `TransitFeeds.shipSources` keeps only operators near BOTH ends. The ship
  card asks twice: once from the trip's ends to find the terminals, then from
  the boarding terminal at the time the rider reaches it (tomorrow's first
  sailing, said so, when none is left today). Cruise lines publish no
  timetables: a cruise is a terminal MapKit finds within 150 km and a search
  the rider can open — nothing booked, no fare guessed, and no "Less
  pollution" chip on a ship.
- **Public fares and the ferry census (2026-09-30) — the owner's rule:**
  "public sources as primaries until affiliate program accounts are made …
  keep FLOWS license free so that it can be commercialized without profit
  sharing." Two sources, both owed nothing:

  *Fares from the feeds themselves.* `fare_attributes.txt` and
  `fare_rules.txt` (GTFS Fares v1) joined `GTFSZip.wanted`; a feed fetched
  before is refetched once (the `.fetched` stamp now holds the wanted list).
  `gtfs::read_route_fares` gives each GTFS route a fare when a rule names the
  route, the whole feed or its agency, or the feed has one flat fare (NYC
  Ferry, $4.50); a fare that depends on origin/destination/contains zones is
  never guessed. Among several that fit, the adult ones win (Cape May–Lewes
  lists every category and season; the least is the free under-six fare),
  then those not marked reduced; one price, or the least said "from". Fares
  ride in `.fts` v2 (CURRENCIES + FARES sections; written only when a feed
  has fares, so every other shard keeps its v1 bytes) and on each `leg` row
  (`fare_cents␟currency␟from`). Cards say a published fare as it is ("$10.25",
  "free", "from $10.00") and "est." only when something in the total is.
  Seen in the feeds: Washington State Ferries $10.25 Seattle–Bainbridge, SF
  Bay Ferry, Steamship Authority, Casco Bay, Black Ball, Kitsap, Block Island,
  Chicago Water Taxi; Staten Island and BC Ferries ship empty fare files, and
  the MBTA uses Fares v2 (not read yet).

  *The federal ferry census.* `flows_core::ferries` + `ferries_table.rs`,
  generated by `flows-train ferries-table` from BTS's 2024 National Census of
  Ferry Operators (`scripts/fetch_ferry_census.sh`; public domain): 905
  routes, 559 terminals, 162 operators with their own sites. Where no
  timetable feed joins the two places, the ship card shows the census ferry
  (terminals within 40 km of each end, least ground first, and it must leave
  the rider well on): a typical crossing time, crossings a day, its season,
  whether cars go aboard (unknown when the census left it blank — the SS
  Badger), and the operator's site for sailings and fares. Out of season it
  says so and the rest of the selection is planned. A ferry whose timetable
  FLOWS does read borrows the census operator's site for its ticket link.
- **Still ahead:** `backbone.ftt` (Amtrak + VIA), `manifest.ftm`, and the
  mmap zero-copy reader.

## The shipped stopgap: MapKit itineraries, in FLOWS (superseded-by-design, still current UX)

The original stopgap (one nearest-station lookup + a Maps handoff) is gone. What
ships now keeps everything **in FLOWS** — no Apple Maps handoff — while honestly
labelling what it can't know without GTFS:

- **Full multi-leg itineraries** (`apple/FLOWS/Sources/Core/TransitItinerary.swift`,
  built by `computeGroundTransit(rail:)` in `apple/FLOWS/Sources/UI/RouteChoicesView.swift`):
  walk to the boarding station → intercity/local RIDE → **walk from the arrival
  station** (the traveller doesn't have their car at the far end). WALK legs are
  real MapKit pedestrian routes with step instructions; the RIDE leg is drawn
  along the real ground corridor between stations (MapKit road geometry, straight
  connector only if unroutable — `rideGeometryIsReal` gates the claim) and flagged
  `rideGeometryIsApproximate` until GTFS supplies true rail shapes.
- **Bundled Amtrak station list** (`AmtrakStations.swift` +
  `Resources/amtrak_stations.json`): every rail-served Amtrak station
  (name/code/lat/lon; 536 stations from Amtrak's public GTFS `stops.txt`,
  Thruway bus-only stops excluded — source + retrieval date documented in the
  JSON itself). Long-haul rail board/alight is a pure offline nearest-station
  lookup over this list (radius-capped, tested); MKLocalSearch remains only
  the off-list fallback and the source for local rail + bus. This fixed rail
  routing failing for most destinations — the text search missed most
  stations; the published list can't.
- **Plane option** (`computeAirTransit` + `AirTravel.swift`): a third toggle
  that boards at the nearest airport with airline service at each end
  (MapKit `.airport` POI category filtered by a tested name-based commercial
  screen — heliports/private strips/military fields rejected, internationals
  preferred). Timing is honest door-to-door: 90 min early + taxi/climb +
  cruise + 30 min bags, all inside the leg. Fare is a floor+per-mile estimate
  labelled "airlines set the real price"; the ticket link is the airport's
  own page or a keyless neutral flight search. Rentals reuse the transit-card
  mechanism, centered on the ARRIVAL airport. No CO₂ chip — flying doesn't
  earn it.
- **Walk + paid ride** (`computeHybrid` + `HybridWalk.swift`): when walking
  is the only selected mode, one extra option offers a rideshare segment
  ONLY when it clears a significance bar — ≥40% AND ≥15 min of the
  walk-alone time saved for ≤$25 estimated ($3 base + $1.10/mi, labelled a
  guess; Uber/Lyft price for real). Whole-trip ride when the cap affords it,
  else ride the first affordable miles and walk the rest (drop-off
  interpolated along the drive geometry, the walk remainder re-routed for
  real and the bar re-checked). Hail links are keyless universal links
  (m.uber.com/ul, lyft.com/ride) carrying pickup + drop-off coordinates.
- **Honest, mode-differentiated timing:** `TransitPlanning.rideDuration` scales a
  measured MapKit drive time by a per-mode door-to-door overhead
  (`rideMultiplier`: Amtrak 1.45 / Greyhound 1.35 / local rail 1.30 / bus 2.0),
  falling back to conservative effective speeds (`fallbackMPH`, kept monotonic
  with the multipliers so mode ordering never flips) — labelled an estimate until
  GTFS lands.
- **Rail + bus + plane multi-select cards:** `RouteChoicesView.TransitOption`
  keyed by `TransitMode` — cards coexist, each carries **its own itinerary**;
  tapping a card draws *its* legs on the map (`activeTransitModes` set,
  latest-computed wins, stale async results are dropped by generation check).
- **Nearest-Amtrak recommendation:** when no rail is in range, the card still
  helps — the bundled station list names the closest Amtrak station within
  intercity range, offline ("No rail close by. Closest train: …, N mi away").
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
- **A service day holds the days before it too (2026-09-30).** GTFS files a trip
  under the day it *starts*: the 11:50 PM bus is `24:10:00` at its last stop and
  the 2 AM owl bus `26:00:00`, both on YESTERDAY's service. A timetable of the
  day's own trips had nothing after midnight — no owl buses, and a Cleveland rider
  at 1 AM was shown tomorrow's 5:50 AM Lake Shore Limited instead of this
  morning's. So `parse_feed` also takes trips that ran up to `CARRY_DAYS` (3)
  days before, keeps the part running after today's midnight, and moves it onto
  today's clock (`carried`). A trip that ran only on an earlier day keeps just
  its rows from today on, plus its last timed stop before as an anchor for the
  untimed stops after it — memory and build time stay where they were (Chicago:
  +1 MB, CPU within noise).
- **Times run to hour 168, not 48.** Amtrak stores the Sunset Limited's arrival at
  `56:35:00` and the Texas Eagle's through cars at `80:00:00`. A 48-hour cap
  blanked those times, and a trip with a blank last stop is dropped: 70 Amtrak
  trips, whole long-distance trains, were missing. `TransitClock.instant` takes
  the same bound, and a ride that ends on a later day says so ("next day",
  "2 days later").
- **Agency timezone is load-bearing** — and the rule is narrower than it looks.
  GTFS times are **not** local to the stop: the reference requires every time in
  `stop_times.txt` to be measured from midnight in the *agency's* zone, so a
  single feed is already internally consistent and needs no normalization.
  Amtrak's corridor spans ET→CT→MT→PT in *stop* zones while storing everything
  in ET, which is why `.fts` carries both: one agency zone to anchor the day,
  one zone per stop to render the clock a rider reads on the platform. The
  normalization the stitch really needs is across **different feeds**, when
  their agency zones differ.
- **`shapes.txt` is display-only** — not needed for routing and often the 2nd-largest
  file. Drop it from the hot routing arrays; keep a downsampled copy only for drawing
  the ride leg (or omit and draw station-to-station until it lands).

## FFI (C-ABI) — HISTORICAL, NOT THE PLAN

> **Superseded.** `rust/flows-core/src/ffi.rs` was deleted with the rest of the
> C-ABI layer when the project moved to swift-bridge; `flows_transit_plan` and
> `flows_transit_selftest` are gone and nothing called them. The transit surface
> will cross as a `#[swift_bridge::bridge]` module over `transit::shard.rs`,
> registered in `rust/flows-bridge/build.rs`'s `BRIDGES` and wrapped in a Swift
> facade, exactly like every other FLOWS module. The section below is retained
> only because the *shape* of the query it describes (open a shard, scope it,
> plan, pull names and leg shapes) is still the right decomposition.

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
journey reconstruction lives inside `transit::raptor` rather than a separate
`transit::journey`, and the FFI structs are gone entirely with `ffi.rs`. The
planned split below still holds for the pieces not yet written.

- `transit` (mod.rs) — **built**: the in-memory CSR timetable + builder (Phase 0);
  the structs are field-width-matched to the `.ftt` sections on purpose.
- `transit::raptor` — **built**: the RAPTOR round loop (bicriteria: arrival +
  transfers) with bounded-footpath transfers, journey reconstruction (`plan`,
  `earliest_arrival`), and the Dijkstra correctness gate.
- `transit::ftt` — **built**: `.ftt` v1 `write_ftt`/`read_ftt` (header +
  fnv1a-64 hash validation + full bounds/CSR-invariant checks; sequential v1
  reader, mmap-ready layout).
- `transit::gtfs` — **built**: streaming CSV, calendar/service-date expansion,
  frequencies expansion, transfers→footpaths, the overtaking-split RAPTOR route
  derivation, and the label columns the sidecar needs — `stop_timezone`,
  `agency.txt`'s `agency_timezone`, and `feed_info.txt`'s publication date
  (`load_gtfs(dir, date) -> GtfsLoad { Timetable, names, zones, dates, stats }`).
  No longer offline-only: the device builds its own shards from downloaded
  feeds, so this code ships.
  Every file is opened through `transit::inflate::open_member`, plain or packed.
- `transit::inflate` — **built (2026-09-30)**: pure-std raw DEFLATE (RFC 1951)
  and CRC-32, streaming at fixed memory, so a feed member stays compressed on
  the device (`stop_times.txt.fz`) and is unpacked as it is parsed; the packed
  header's length and CRC are checked when the stream ends.
- `transit::fts` — **built**: `.fts` v1, the label sidecar (stop names, station
  codes, IANA zones, service + publication dates), paired to its `.ftt` by body
  hash and fully bounds-/UTF-8-checked on read.
- `transit::shard` — **built**: `build`/`write`/`open` for the pair, plus
  `nearest_stops` and `departures` — the whole surface Swift needs, clock-free.
- `transit::mcraptor` — Pareto bag labels for the walking (then fare) axes;
  feature-gated so bicriteria ships first with zero bag overhead.
- `transit::engine` — the opaque `TransitEngine`: holds mapped shards, resolves
  twin-stop joins into one logical timetable, does nearest-boardable-stop resolution
  (via `distance.rs`), owns the query entry.
- `transit::csa` — documented CSA fallback over the same format.
- `flows-bridge` (new module) — the swift-bridge forwarders over
  `transit::shard`, registered in that crate's `build.rs` `BRIDGES`.

## Phased build plan

- **Phase 0 — engine core — ✅ DONE (pure Rust, no device, no feeds):** the
  in-memory CSR timetable + builder, bicriteria RAPTOR + journey reconstruction, and
  the **correctness gate** (RAPTOR earliest-arrival == time-dependent Dijkstra on
  random timetables) — all in `flows-core::transit`, `cargo test`-verified. The
  `flows_transit_plan`/`flows_transit_selftest` C-ABI FFI also landed early, but
  both were deleted in the swift-bridge migration (see the correction above).
  _(From Phase 0's
  tail, owned CSV + the `.ftt` writer/reader landed with Phase 1 below; owned
  `inflate` stays queued — `unzip` is build-host tooling for now.)_
- **Phase 1 — first vertical slice — feed→`.ftt` ✅ DONE (2026-07-10), Swift wiring NEXT:**
  the GTFS parser (`transit::gtfs`), the `.ftt` v1 writer/reader with hash
  validation (`transit::ftt`), the `gtfs-ftt` converter CLI, and
  `scripts/fetch_gtfs.sh`/`scripts/build_ftt.sh` — verified end-to-end on the
  real Madison Metro feed (round-trip byte-identical, plans identical on
  original vs reloaded; see Status). **Usage:**
  `scripts/fetch_gtfs.sh <feed-url> <name>` then `scripts/build_ftt.sh <name>
  [YYYYMMDD]` → `data/transit/<name>.ftt` **and `.fts`**. Remaining for the
  slice: the **device-side supply line** (download the feed over Wi-Fi, unzip
  it, build the pair into Caches, conditional-GET refresh, never while
  navigating); the **swift-bridge module** over `transit::shard` + its Swift
  facade; the wall-clock conversion in Swift (`agency-midnight + seconds`,
  rendered per stop zone) with its own tests; real departure and arrival times
  on the rail card; then Amtrak + VIA → `backbone` + `manifest.ftm` (cross-FEED
  zone normalization at the stitch); extend `TransitLeg` with `case transfer`;
  retire the MapKit stopgap. Golden-hash the backbone build and known OD pairs.
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
