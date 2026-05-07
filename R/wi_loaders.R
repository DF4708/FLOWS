# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/wi_loaders.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: every spatial layer in the app keys off two reference geometries — the
# WI county polygons and the WI ZCTA polygons — and we need them in CRS 4326
# with consistent column names and a county_name lookup attached to each ZIP.
# What: returns a list(zctas, counties) where zctas has zipcode / geometry /
# county_index / county_geoid / county_name and counties has NAME / GEOID /
# COUNTYFP / geometry, both in EPSG:4326.
# How: pulls each layer through require_reference_layer (local GPKG first,
# Census TIGER as remote fallback), strips to the columns the rest of the
# app uses, intersects ZCTAs with the unioned WI state geometry to drop
# out-of-state polygons, and joins each ZIP to its containing county via a
# point-on-surface intersect.
# When: called once at the very top of global.R; the resulting wi_zctas /
# wi_counties bindings are referenced everywhere downstream.
# Impact: this is the only function that materialises wi_state_geom inline;
# any change to the column-stripping list above will silently drop fields the
# rest of the codebase reads via direct $-accessors.
load_reference_geographies <- function() {
  counties <- require_reference_layer(
    "counties",
    remote_loader = function() {
      obj <- read_reference_sf("reference", "counties", CENSUS_COUNTY_URL)
      obj[obj$STATEFP == TARGET_STATE_FIPS, , drop = FALSE]
    }
  )
  county_keep <- intersect(names(counties), c("NAME", "GEOID", "COUNTYFP", "geometry"))
  counties <- counties[, county_keep, drop = FALSE]
  if (!"GEOID" %in% names(counties) && "COUNTYFP" %in% names(counties)) {
    counties$GEOID <- paste0(TARGET_STATE_FIPS, counties$COUNTYFP)
  }
  counties <- ensure_crs_4326(counties)
  wi_state_geom <- suppressWarnings(sf::st_union(counties))

  zctas <- require_reference_layer(
    "zctas",
    remote_loader = function() {
      obj <- read_reference_sf("reference", "zctas", CENSUS_ZCTA_URL)
      names(obj)[names(obj) == "GEOID20"] <- "zipcode"
      obj <- obj[, c("zipcode", "geometry")]
      obj <- ensure_crs_4326(obj)
      keep_idx <- lengths(sf::st_intersects(obj, wi_state_geom)) > 0
      obj[keep_idx, , drop = FALSE]
    }
  )
  if (!"zipcode" %in% names(zctas) && "GEOID20" %in% names(zctas)) names(zctas)[names(zctas) == "GEOID20"] <- "zipcode"
  zctas <- zctas[, c("zipcode", "geometry"), drop = FALSE]
  zctas <- ensure_crs_4326(zctas)

  county_hits <- sf::st_intersects(point_on_surface_lonlat(zctas), counties)
  zctas$county_index <- vapply(
    county_hits,
    function(x) if (length(x) == 0) NA_integer_ else x[1],
    integer(1)
  )
  zctas$county_geoid <- counties$GEOID[pmax(1L, zctas$county_index)]
  zctas$county_geoid[is.na(zctas$county_index)] <- NA_character_
  zctas$county_name <- counties$NAME[pmax(1L, zctas$county_index)]
  zctas$county_name[is.na(zctas$county_index)] <- NA_character_

  list(zctas = zctas, counties = counties)
}

# Why: the geocoder needs WI city / village / town polygons to resolve
# place-name queries to spatial geometries; we cache the layer for 24h since
# Census places change rarely.
# What: returns an sf data.frame of WI places with columns NAME and geometry
# in EPSG:4326.
# How: lazy-loads from the local reference GPKG via require_reference_layer
# (remote fallback to CENSUS_PLACE_URL), trims to NAME / geometry, renames
# NAMELSAD to NAME if present, and caches.
# When: invoked by resolve_search_query when matching place tokens, and
# any other code that needs city polygons.
# Impact: the 24h TTL is fine for boundary stability; if Census publishes
# a new vintage you may need to invalidate the "places" cache key manually.
load_places <- function() {
  cached <- cache_get("derived", "places")
  if (!is.null(cached)) return(cached)
  places <- require_reference_layer(
    "places",
    remote_loader = function() read_reference_sf("reference", "places", CENSUS_PLACE_URL)
  )
  nm <- intersect(names(places), c("NAME", "NAMELSAD", "geometry"))
  places <- places[, nm]
  if (!"NAME" %in% names(places) && "NAMELSAD" %in% names(places)) names(places)[names(places) == "NAMELSAD"] <- "NAME"
  places <- ensure_crs_4326(places)
  cache_put("derived", "places", places, ttl_seconds = 24 * 3600)
  places
}

# Why: every popup needs to label its ZIP with the containing place name
# (city / village); doing the spatial join on every popup render would be
# wasteful, so we precompute the map once.
# What: returns a named character vector keyed by zipcode whose values are
# the matching place NAME (or NA when no place contains the ZIP point).
# How: takes the point-on-surface of each WI ZCTA, intersects against the
# loaded places layer, and assigns the first matching place NAME to each
# ZIP; result is cached for 24h alongside the places layer itself.
# When: invoked by apply_cached_place_names inside build_forecast_baseline
# and from any popup helper that needs the city label.
# Impact: a ZIP whose centroid falls outside every place polygon (rural
# unincorporated land) ends up with NA — popups handle that by showing
# the county name instead.
load_zip_place_lookup <- function() {
  cached <- cache_get("derived", "zip_place_lookup")
  if (!is.null(cached)) return(cached)
  places <- load_places()
  lookup <- setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  if (nrow(places) == 0 || nrow(wi_zctas) == 0) {
    cache_put("derived", "zip_place_lookup", lookup, ttl_seconds = 24 * 3600)
    return(lookup)
  }
  zip_points <- point_on_surface_lonlat(wi_zctas)
  hits <- sf::st_intersects(zip_points, places)
  resolved <- vapply(
    hits,
    function(idx) {
      if (length(idx) == 0) return(NA_character_)
      as.character(places$NAME[idx[1]])
    },
    character(1)
  )
  lookup[wi_zctas$zipcode] <- resolved
  cache_put("derived", "zip_place_lookup", lookup, ttl_seconds = 24 * 3600)
  lookup
}

# Why: every routing query needs the same WI road network as an sf object;
# loading and standardising it on every call would dominate latency, so we
# load once and cache.
# What: returns an sf data.frame of WI drivable ways with road_id, route_tier,
# road_class, base_speed_mph, and LINESTRING geometry in EPSG:4326.
# How: prefers the OSM-derived RDS (data/reference/wi_osm_roads.rds) which
# has clean junction topology and ~97k ways; falls back to the legacy TIGER
# PRISECROADS shapefile if the OSM file is absent. Result is normalised to
# the columns the rest of the routing pipeline depends on, then cached.
# When: called inside build_route_segments and build_native_route_object on
# the first routing request after process start (or after a cache flush).
# Impact: choice of OSM vs TIGER changes the size and connectivity of the
# graph - OSM has 16x more edges and far fewer artificial fragmentation
# issues, but is also why downstream code had to be vectorised.
load_wi_roads <- function() {
  cached <- cache_get("reference", "wi_prisecroads")
  if (!is.null(cached)) return(cached)
  # Prefer the OSM-derived road network when present: full intersection
  # topology (no TIGER ramp gaps), drivable highways down to tertiary plus
  # *_link ramps. The cache is built once by scripts/build_osm_roads.R.
  osm_path <- file.path("data", "reference", "wi_osm_roads.rds")
  if (file.exists(osm_path)) {
    roads <- tryCatch(readRDS(osm_path), error = function(e) NULL)
    if (!is.null(roads) && inherits(roads, "sf") && nrow(roads) > 0) {
      roads <- ensure_crs_4326(roads)
      keep <- intersect(names(roads), c("road_id", "road_name", "highway",
                                         "route_tier", "road_class",
                                         "base_speed_mph", "oneway",
                                         "susceptibility", "geometry"))
      roads <- roads[, keep, drop = FALSE]
      if (!"susceptibility" %in% names(roads)) {
        roads$susceptibility <- ifelse(roads$road_class == "Primary", 1.00, 0.85)
      }
      cache_put("reference", "wi_prisecroads", roads, ttl_seconds = 24 * 3600)
      return(roads)
    }
  }
  roads <- require_reference_layer(
    "roads",
    remote_loader = function() read_reference_sf("reference", "wi_prisecroads_raw", CENSUS_PRISECROADS_URL)
  )
  keep <- intersect(names(roads), c("LINEARID", "FULLNAME", "RTTYP", "MTFCC", "road_id", "road_name", "road_class", "susceptibility", "geometry"))
  roads <- roads[, keep, drop = FALSE]
  roads <- ensure_crs_4326(roads)
  roads <- roads[lengths(sf::st_intersects(roads, wi_state_geom)) > 0, , drop = FALSE]
  if (!"road_id" %in% names(roads)) roads$road_id <- as.character(roads$LINEARID %||% seq_len(nrow(roads)))
  if (!"road_name" %in% names(roads)) {
    roads$road_name <- trimws(as.character(roads$FULLNAME %||% ""))
    blank_name <- !nzchar(roads$road_name)
    roads$road_name[blank_name] <- ifelse(roads$MTFCC[blank_name] == "S1100", "Primary road", "Secondary road")
  }
  if (!"road_class" %in% names(roads)) roads$road_class <- ifelse(roads$MTFCC == "S1100", "Primary", "Secondary")
  classify_route_tier <- function(rttyp = "", road_class = "", road_name = "") {
    tier_code <- toupper(trimws(as.character(rttyp %||% "")))
    if (tier_code == "I" || grepl("\\bI\\s*-?\\s*\\d+\\b", road_name %||% "", perl = TRUE, ignore.case = TRUE)) return("Interstate")
    if (tier_code == "U") return("US")
    if (tier_code == "S") return("State")
    if (tier_code == "C") return("County")
    if (tier_code == "M") return("Major")
    if (identical(as.character(road_class %||% ""), "Primary")) return("Primary")
    "Secondary"
  }
  route_tier_speed_mph <- function(route_tier = "") {
    tier <- as.character(route_tier %||% "Secondary")
    switch(
      tier,
      Interstate = 74,
      US = 58,
      State = 48,
      County = 40,
      Major = 35,
      Primary = 33,
      Secondary = 28,
      Connector = 18,
      28
    )
  }
  roads$route_tier <- vapply(
    seq_len(nrow(roads)),
    function(i) classify_route_tier(roads$RTTYP[i] %||% "", roads$road_class[i] %||% "", roads$road_name[i] %||% ""),
    character(1)
  )
  roads$base_speed_mph <- vapply(roads$route_tier, route_tier_speed_mph, numeric(1))
  if (!"susceptibility" %in% names(roads)) roads$susceptibility <- ifelse(roads$road_class == "Primary", 1.00, 0.85)
  cache_put("reference", "wi_prisecroads", roads, ttl_seconds = 24 * 3600)
  roads
}

# Why: a number of layers (alerts, RadNet, NRC, GLM lightning) need the
# polygons of the five states bordering Wisconsin so we can extend hazard
# proximity scoring into adjacent territory.
# What: returns an sf of the five border-state polygons with columns NAME /
# STATEFP / STUSPS / geometry in EPSG:4326.
# How: pulls all US states via require_reference_layer, filters by
# BORDER_STATE_FIPS, and caches.
# When: called once per session by any module that does cross-border
# proximity work; cached for 24h.
# Impact: changing BORDER_STATE_FIPS in global.R changes which states this
# returns and ripples through every cross-border scorer downstream.
load_border_states <- function() {
  cached <- cache_get("reference", "border_states")
  if (!is.null(cached)) return(cached)
  states <- require_reference_layer(
    "border_states",
    remote_loader = function() read_reference_sf("reference", "border_states_raw", CENSUS_STATE_URL)
  )
  keep <- intersect(names(states), c("NAME", "STATEFP", "STUSPS", "geometry"))
  states <- states[, keep, drop = FALSE]
  if ("STATEFP" %in% names(states)) {
    states <- states[states$STATEFP %in% BORDER_STATE_FIPS, , drop = FALSE]
  }
  states <- ensure_crs_4326(states)
  cache_put("reference", "border_states", states, ttl_seconds = 24 * 3600)
  states
}

# Why: build_modeled_road_risk_index needs to know which ZIPs each road
# segment passes through; doing the spatial intersect on every routing
# call would be too slow.
# What: returns a named list keyed by road_id whose values are character
# vectors of zipcodes the road intersects.
# How: spatial-intersects load_wi_roads() against wi_zctas and packages the
# index lists, with one list entry per road; cached for 24h.
# When: invoked once on the first routing build per session; reused from
# cache thereafter.
# Impact: if the OSM road set changes (e.g. wi_osm_roads.rds is rebuilt),
# this cache must be invalidated or the road-to-zip mapping will lag.
load_road_zip_lookup <- function() {
  cached <- cache_get("derived", "road_zip_lookup")
  if (!is.null(cached)) return(cached)
  # Disk-persisted snapshot: regenerable from wi_roads + wi_zctas (both stable
  # across sessions), so the first session pays the spatial-intersect cost
  # once and every subsequent R process loads from disk in <1 s.
  snap_path <- runtime_snapshot_file("derived_road_zip_lookup")
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 24 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", "road_zip_lookup", persisted, ttl_seconds = 24 * 3600)
    return(persisted)
  }
  flows_time_step("load_road_zip_lookup (cold build)", {
    roads <- load_wi_roads()
    hits <- sf::st_intersects(roads, wi_zctas)
    lookup <- lapply(
      hits,
      function(idx) {
        as.character(wi_zctas$zipcode[idx])
      }
    )
    names(lookup) <- roads$road_id
    cache_put("derived", "road_zip_lookup", lookup, ttl_seconds = 24 * 3600)
    save_runtime_snapshot(snap_path, lookup)
    lookup
  }, group = "loader")
}

# Why: the OSM road set is ~97k features; projecting to EPSG:5070 takes
# several seconds and ~100MB of working memory. Multiple call sites in the
# 511 / routing pipelines were each running their own st_transform pass,
# which compounded cold-start cost. Caching the projected sf once per session
# keeps all those call sites cheap on the second-and-later use.
# What: returns the projected (EPSG:5070) version of load_wi_roads() with
# all its columns intact.
# How: cache lookup keyed by "wi_roads_proj"; on miss, projects load_wi_roads()
# once and stores for 24 hours (matches the road-zip lookup TTL so the two
# road-derived artefacts age together).
# When: invoked by 511 snap-to-OSM, 511 road proximity signal, and message-
# sign road signal builders.
# Impact: invalidating the underlying wi_osm_roads.rds requires also
# invalidating this cache key.
load_wi_roads_proj <- function() {
  cached <- cache_get("derived", "wi_roads_proj")
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file("derived_wi_roads_proj")
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 24 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", "wi_roads_proj", persisted, ttl_seconds = 24 * 3600)
    return(persisted)
  }
  flows_time_step("load_wi_roads_proj (cold build)", {
    roads <- load_wi_roads()
    proj <- suppressWarnings(sf::st_transform(roads, 5070))
    cache_put("derived", "wi_roads_proj", proj, ttl_seconds = 24 * 3600)
    save_runtime_snapshot(snap_path, proj)
    proj
  }, group = "loader")
}

# Why: heavy per-OSM-road loops (511 proximity, message-sign proximity,
# overlay snapping) need a stable north-to-south banding so they can report
# incremental progress and keep per-band working sets small. Computing the
# bands once per session matches how wi_zctas$lat_band is initialised at
# global.R load-time and reused across the per-ZIP banded flow.
# What: returns a list with two parallel structures keyed by the same
# load_wi_roads() row order: `bands` is an integer vector (1..n_bands) per
# road, and `groups` is a list of row-index vectors, one per band, ordered
# north-to-south so iteration matches the existing latitude_band_row_groups
# convention.
# How: takes the centroid of each road's projected geometry, transforms back
# to EPSG:4326 for latitude, applies assign_lat_band() with the same bounds
# used for ZIPs, then reorders the band ids descending.
# When: invoked once per session by the 511 road-level helpers; cached for
# 24 hours alongside load_wi_roads_proj so both road-derived artefacts age
# together.
# Impact: rebuilding wi_osm_roads.rds requires invalidating this cache key.
# Why: when scoring per-road risk, taking the MAX over every ZIP a road
# touches penalises long Secondary roads that briefly clip a green ZIP
# corner — the road inherits that green tag for its entire length even when
# 95% of it is in transparent ZIPs. Length-weighted aggregation needs to
# know how many metres of each road sit in each ZIP. This lookup gives that.
# What: returns a named list keyed by road_id; each entry is a named numeric
# vector mapping zipcode -> length_m_in_that_zip. Roads that fall entirely
# outside any ZIP are absent from the list.
# How: projects roads + wi_zctas to EPSG:5070, computes the geometric
# intersection (which yields one row per (road x zcta) overlap piece),
# measures each piece's length, then sums by (road_id, zipcode). Cached for
# 24 hours alongside road_zip_lookup so both age together when wi_osm_roads
# is rebuilt.
# When: invoked the first time build_modeled_road_risk_index runs in a
# session and length-weighted scoring kicks in. The intersection pass is
# the costly bit (~30-90 s on the ~84k-road x 861-ZIP cross), but it
# happens once per session.
# Impact: missing or zero-length entries fall back to MAX-of-ZIPs scoring
# inside build_modeled_road_risk_index, so a partial cache miss does not
# degrade silently — it just reverts to the prior behaviour for that road.
load_road_zip_length_lookup <- function() {
  cache_key <- "road_zip_length_lookup"
  cached <- cache_get("derived", cache_key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", cache_key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 24 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", cache_key, persisted, ttl_seconds = 24 * 3600)
    return(persisted)
  }
  flows_time_step("load_road_zip_length_lookup (cold build)", {
    roads <- load_wi_roads()
    if (nrow(roads) == 0) {
      out <- list()
      cache_put("derived", cache_key, out, ttl_seconds = 24 * 3600)
      return(out)
    }

    roads_proj <- load_wi_roads_proj()
    zctas_proj <- tryCatch(suppressWarnings(sf::st_transform(wi_zctas, 5070)),
                           error = function(e) NULL)
    if (is.null(zctas_proj)) {
      out <- list()
      cache_put("derived", cache_key, out, ttl_seconds = 24 * 3600)
      return(out)
    }

    inter <- tryCatch(
      suppressWarnings(sf::st_intersection(roads_proj, zctas_proj)),
      error = function(e) NULL
    )
    if (is.null(inter) || nrow(inter) == 0) {
      out <- list()
      cache_put("derived", cache_key, out, ttl_seconds = 24 * 3600)
      return(out)
    }

    piece_length_m <- as.numeric(suppressWarnings(sf::st_length(inter)))
    inter_df <- sf::st_drop_geometry(inter[, c("road_id", "zipcode"), drop = FALSE])
    inter_df$piece_length_m <- piece_length_m
    inter_df <- inter_df[is.finite(inter_df$piece_length_m) & inter_df$piece_length_m > 0, , drop = FALSE]
    if (nrow(inter_df) == 0) {
      out <- list()
      cache_put("derived", cache_key, out, ttl_seconds = 24 * 3600)
      return(out)
    }

    agg <- dplyr::summarise(
      dplyr::group_by(inter_df, road_id, zipcode),
      length_m = sum(piece_length_m, na.rm = TRUE),
      .groups = "drop"
    )
    agg$road_id <- as.character(agg$road_id)
    agg$zipcode <- as.character(agg$zipcode)
    out <- split(agg, agg$road_id)
    out <- lapply(out, function(df) stats::setNames(as.numeric(df$length_m), df$zipcode))
    cache_put("derived", cache_key, out, ttl_seconds = 24 * 3600)
    save_runtime_snapshot(snap_path, out)
    out
  }, group = "loader")
}

# Why: downstream layers need this reference data in a known shape; loading
# it via a single helper centralises the path / version handling.
# What: see body — load_wi_roads_lat_band_groups is documented here for the
# first time.
# How: cache lookup + put + sf geometry op + row/element loop + guarded
# numeric coercion.
# When: called once at module-load time or on the first request that needs
# the reference data; cached for the rest of the session.
# Impact: invalidating the on-disk snapshot is the main lever for picking
# up updated reference data without restarting the session.
load_wi_roads_lat_band_groups <- function(n_bands = 10L, descending = TRUE) {
  cache_key <- sprintf("wi_roads_lat_bands_%d_%d", as.integer(n_bands), as.integer(descending))
  cached <- cache_get("derived", cache_key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", cache_key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 24 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", cache_key, persisted, ttl_seconds = 24 * 3600)
    return(persisted)
  }
  roads_proj <- load_wi_roads_proj()
  cents_proj <- suppressWarnings(sf::st_centroid(sf::st_geometry(roads_proj)))
  cents_lonlat <- suppressWarnings(sf::st_transform(
    sf::st_sfc(cents_proj, crs = sf::st_crs(roads_proj)), 4326))
  coords <- suppressWarnings(sf::st_coordinates(cents_lonlat))
  lat <- coords[, "Y"]
  bands <- assign_lat_band(lat, wi_bounds$south, wi_bounds$north, n_bands)
  band_order <- if (isTRUE(descending)) seq.int(n_bands, 1L) else seq.int(1L, n_bands)
  groups <- lapply(band_order, function(b) which(bands == b))
  out <- list(bands = bands, groups = groups, order = band_order)
  cache_put("derived", cache_key, out, ttl_seconds = 24 * 3600)
  save_runtime_snapshot(snap_path, out)
  out
}

# Why: the live road overlay only needs to redraw the segments near elevated
# driving risk; carrying every road in the state through the overlay build
# would dominate map render latency.
# What: returns a character vector of zipcodes whose driving_total_risk is
# at or above min_score, expanded by their immediate neighbours so the
# overlay does not abruptly clip at high-risk zone edges.
# How: filters zips by driving_total_risk >= min_score, then unions the
# neighbour-sets via get_zip_neighbors so adjacent low-risk zips that share
# a road with a hot zip are also included.
# When: called by build_driving_roads_overlay before subsetting the road
# network for the live overlay.
# Impact: lowering min_score widens the overlay (more roads, more redraw
# cost); raising it can hide marginal yellow stretches that still deserve
# the badge.
get_relevant_road_zipcodes <- function(zips, min_score = 0.02) {
  if (is.null(zips) || nrow(zips) == 0) return(character(0))
  vals <- suppressWarnings(as.numeric(zips$driving_total_risk %||% rep(0, nrow(zips))))
  vals[!is.finite(vals)] <- 0
  hot_idx <- which(vals >= min_score)
  if (length(hot_idx) == 0) return(character(0))

  neighbors <- get_zip_neighbors()
  neighbor_idx <- unique(unlist(neighbors[hot_idx], use.names = FALSE))
  keep_idx <- sort(unique(c(hot_idx, neighbor_idx)))
  as.character(zips$zipcode[keep_idx])
}

# Why: the modelled (no-overlay) road-risk path needs a per-road risk score
# and the matching reason text so build_route_segments can emit a coherent
# popup explanation even when WI511 / NWS road overlays are unavailable.
# What: returns a data.frame(road_id, driving_total_risk, driving_reason_text,
# dominant_zip, road_source, official_cause_text) with one row per road in
# the input.
# How: builds zip-keyed driving_risk / reason / transport-reason lookup
# tables, then for each road uses the precomputed road-zip lookup to find
# its intersecting ZIPs, picks the worst one as dominant_zip (tie-break by
# index order), and propagates that zip's reason / cause through.
# When: called from build_route_segments when no roads_overlay is supplied,
# i.e. on every routing build that does not have a live transport feed.
# Impact: the road_mult formula (0.85 + 0.15 * susceptibility) is the only
# place road class is allowed to influence modelled risk; if susceptibility
# is set to 0 the modelled risk floors at 0.85 of the worst zip's risk.
build_modeled_road_risk_index <- function(roads, lookup, zips) {
  if (is.null(roads) || nrow(roads) == 0 || is.null(zips) || nrow(zips) == 0) {
    return(data.frame(
      road_id = character(0),
      driving_total_risk = numeric(0),
      driving_reason_text = character(0),
      dominant_zip = character(0),
      road_source = character(0),
      official_cause_text = character(0),
      stringsAsFactors = FALSE
    ))
  }

  zip_drive <- stats::setNames(suppressWarnings(as.numeric(zips$driving_total_risk %||% rep(0, nrow(zips)))), zips$zipcode)
  zip_drive[!is.finite(zip_drive)] <- 0
  zip_reason <- stats::setNames(as.character(zips$driving_reason_text %||% rep("", nrow(zips))), zips$zipcode)
  zip_transport_reason <- stats::setNames(as.character(zips$wi511_transport_reason %||% rep("", nrow(zips))), zips$zipcode)
  road_ids <- as.character(roads$road_id %||% rep("", nrow(roads)))
  n_roads <- length(road_ids)

  # Per-road, per-ZIP length lookup powers length-weighted scoring. When
  # missing or empty, individual roads transparently fall back to MAX-of-ZIPs
  # below — so this is a strict refinement that never makes things worse.
  length_lookup <- tryCatch(load_road_zip_length_lookup(), error = function(e) NULL)
  if (!is.null(length_lookup) && length(length_lookup) == 0) length_lookup <- NULL

  # Pre-subset both lookups by road_ids ONCE rather than lookup[[id]] inside
  # each vapply iteration. R's [character_vec] indexing on a named list
  # builds a hash table the first time, so the slice runs in O(n_roads)
  # rather than O(n_roads * len(lookup)) (the latter was minutes for ~25k
  # filtered roads vs an 84k-entry lookup; profiling confirmed do_subset2_dflt
  # was the dominant frame).
  lookup_subset <- lookup[road_ids]
  length_lookup_subset <- if (!is.null(length_lookup)) length_lookup[road_ids] else NULL
  road_susceptibility <- suppressWarnings(as.numeric(roads$susceptibility %||% rep(1, n_roads)))
  road_susceptibility[!is.finite(road_susceptibility)] <- 1
  road_mult <- 0.85 + 0.15 * road_susceptibility

  # Flatten road->zip mappings into long-form vectors. Each entry is one
  # (road, zip) pair; aggregations below collapse across n_roads via
  # rowsum / order / duplicated in C-level loops, replacing four R-level
  # vapply iterations that previously dominated this function (~10s for
  # ~93k roads in a typical build).
  zips_per_road <- lengths(lookup_subset)
  if (!any(zips_per_road > 0L)) {
    return(data.frame(
      road_id = road_ids,
      driving_total_risk = rep(0, n_roads),
      driving_reason_text = rep("All clear.", n_roads),
      dominant_zip = rep(NA_character_, n_roads),
      road_source = rep("Modeled ZIP risk", n_roads),
      official_cause_text = rep("none", n_roads),
      stringsAsFactors = FALSE
    ))
  }

  flat_road_idx <- rep.int(seq_len(n_roads), zips_per_road)
  flat_zip <- unlist(lookup_subset, use.names = FALSE)
  flat_risk <- unname(zip_drive[flat_zip])
  # Missing zips (not in zip_drive) come back NA -> -Inf for max selection,
  # 0 for length-weighted numerator (matches the old vapply path which
  # filtered with is.finite for max and na.rm = TRUE for the weighted sum).
  finite_mask <- is.finite(flat_risk)
  flat_risk_for_max <- ifelse(finite_mask, flat_risk, -Inf)
  flat_risk_for_num <- ifelse(finite_mask, flat_risk, 0)

  # Per-road dominant zip = argmax of zip_drive over its zip set, breaking
  # ties by first-appearance order (matches `which.max(...)[1]` original).
  ord <- order(flat_road_idx, -flat_risk_for_max)
  first_in_group <- !duplicated(flat_road_idx[ord])
  best_in_flat <- ord[first_in_group]
  best_road_for_group <- flat_road_idx[best_in_flat]
  best_risk_for_group <- flat_risk_for_max[best_in_flat]
  has_finite_best <- is.finite(best_risk_for_group)

  best_risk_per_road <- rep(-Inf, n_roads)
  best_risk_per_road[best_road_for_group] <- best_risk_for_group
  dominant_zip <- rep(NA_character_, n_roads)
  dominant_zip[best_road_for_group[has_finite_best]] <-
    flat_zip[best_in_flat[has_finite_best]]

  # Length-weighted mean: numerator and denominator collapse via rowsum
  # (C-level grouped sum). Per-road fall back to max when the road has no
  # usable lens (no length_lookup entry, all zeros, all non-finite/negative).
  if (!is.null(length_lookup_subset)) {
    flat_lens <- unlist(
      Map(
        function(z, l) {
          if (is.null(l) || length(l) == 0L || length(z) == 0L) return(rep(0, length(z)))
          v <- suppressWarnings(as.numeric(l[z]))
          v[!is.finite(v) | v < 0] <- 0
          v
        },
        lookup_subset,
        length_lookup_subset
      ),
      use.names = FALSE
    )
    if (length(flat_lens) != length(flat_road_idx)) {
      flat_lens <- rep(0, length(flat_road_idx))
    }
    # Zero out lens where the risk lookup itself was non-finite. The old
    # path indexed `lens_named[names(vals)]` AFTER filtering vals to finite,
    # so missing-zip lengths were never in the denominator. Without this,
    # a road with one finite-val zip and one missing zip would dilute the
    # weighted mean by the missing zip's length.
    flat_lens[!finite_mask] <- 0
    risk_x_len <- rowsum(flat_risk_for_num * flat_lens, flat_road_idx, na.rm = TRUE)
    len_sum    <- rowsum(flat_lens,                     flat_road_idx, na.rm = TRUE)
    group_key_int <- as.integer(rownames(risk_x_len))
    weighted_per <- numeric(n_roads)
    has_len      <- numeric(n_roads)
    weighted_per[group_key_int] <- as.numeric(risk_x_len) / pmax(as.numeric(len_sum), .Machine$double.eps)
    has_len[group_key_int]      <- as.numeric(len_sum)
    use_weighted <- has_len > 0
    max_finite <- ifelse(is.finite(best_risk_per_road), best_risk_per_road, 0)
    blended <- ifelse(use_weighted, weighted_per, max_finite)
    driving_total_risk <- pmin(1, blended * road_mult)
  } else {
    max_finite <- ifelse(is.finite(best_risk_per_road), best_risk_per_road, 0)
    driving_total_risk <- pmin(1, max_finite * road_mult)
  }

  # Reasons / source / cause: pure per-road lookups keyed by dominant_zip.
  reason_at_best    <- unname(zip_reason[dominant_zip])
  transport_at_best <- unname(zip_transport_reason[dominant_zip])
  has_reason    <- !is.na(reason_at_best)    & nzchar(reason_at_best)
  has_transport <- !is.na(transport_at_best) & nzchar(transport_at_best)
  driving_reason_text <- rep("All clear.", n_roads)
  driving_reason_text[has_reason] <- reason_at_best[has_reason]
  use_transport_reason <- !has_reason & has_transport
  driving_reason_text[use_transport_reason] <- transport_at_best[use_transport_reason]
  driving_reason_text[is.na(dominant_zip)] <- "All clear."

  has_transport_trim <- !is.na(transport_at_best) & nzchar(trimws(transport_at_best))
  road_source <- rep("Modeled ZIP risk", n_roads)
  road_source[has_transport_trim & !is.na(dominant_zip)] <-
    "Modeled ZIP risk + 511 ZIP transport signal"

  # classify_official_transport_cause is scalar (cascading grepl with
  # early-return). We hit it once per UNIQUE transport string rather than
  # per road — n_unique << n_roads in practice — and use match() to map
  # back. Plain named-vector indexing breaks here because zips with empty
  # transport reasons map to "" as the key, and `x[""]` returns NA in R
  # (it doesn't match the entry actually named "").
  transport_for_class <- ifelse(is.na(transport_at_best), "", transport_at_best)
  transport_for_class[is.na(dominant_zip)] <- NA_character_
  unique_transport <- unique(transport_for_class[!is.na(transport_for_class)])
  classified_unique <- vapply(
    unique_transport,
    function(t) classify_official_transport_cause(t, "511 ZIP transport"),
    character(1)
  )
  official_cause_text <- rep("none", n_roads)
  has_class <- !is.na(transport_for_class)
  if (any(has_class)) {
    idx <- match(transport_for_class[has_class], unique_transport)
    official_cause_text[has_class] <- classified_unique[idx]
  }

  data.frame(
    road_id = road_ids,
    driving_total_risk = driving_total_risk,
    driving_reason_text = driving_reason_text,
    dominant_zip = dominant_zip,
    road_source = road_source,
    official_cause_text = official_cause_text,
    stringsAsFactors = FALSE
  )
}

# Why: NWS alert payloads carry forecast/public-zone codes (e.g. "WIZ020")
# rather than ZIPs, and we need the matching zone polygons to map zone-
# scoped alerts onto WI ZIPs.
# What: returns an sf data.frame of WI public forecast zones with columns
# STATE / ZONE / STATE_ZONE / NAME / geometry in EPSG:4326, or an empty sf
# of the same shape when the upstream NWS shapefile is missing.
# How: pulls the latest of the two NWS_PUBLIC_ZONE_URLS via fallback,
# filters to STATE == TARGET_STATE and STATE_ZONE matching the WIZ###
# pattern, normalises the zone code to upper-case, and caches for 24h.
# When: called by get_zone_zip_lookup the first time alerts arrive, and
# reused from cache thereafter for the rest of the session.
# Impact: an upstream URL outage falls back to an empty sf; downstream
# zone-to-zip resolution then degrades to county-based fallback, which is
# coarser but does not break the build.
load_public_zones <- function() {
  cached <- cache_get("reference", "wi_public_zones")
  if (!is.null(cached)) return(cached)
  zones <- tryCatch(
    read_reference_sf_fallback("reference", "wi_public_zones", NWS_PUBLIC_ZONE_URLS),
    error = function(e) NULL
  )
  if (is.null(zones)) {
    empty <- wi_counties[0, c("NAME", "geometry")]
    empty$STATE_ZONE <- character(0)
    cache_put("reference", "wi_public_zones", empty, ttl_seconds = 24 * 3600)
    return(empty)
  }
  zones <- ensure_crs_4326(zones)
  keep <- rep(TRUE, nrow(zones))
  if ("STATE" %in% names(zones)) keep <- keep & zones$STATE == TARGET_STATE
  if ("STATE_ZONE" %in% names(zones)) keep <- keep & grepl("^WIZ[0-9]{3}$", zones$STATE_ZONE)
  zones <- zones[keep, , drop = FALSE]
  zone_keep <- intersect(names(zones), c("STATE", "ZONE", "STATE_ZONE", "NAME", "geometry"))
  zones <- zones[, zone_keep, drop = FALSE]
  if (!"STATE_ZONE" %in% names(zones) && all(c("STATE", "ZONE") %in% names(zones))) {
    zones$STATE_ZONE <- paste0(zones$STATE, zones$ZONE)
  }
  if (!"STATE_ZONE" %in% names(zones)) {
    zones$STATE_ZONE <- character(nrow(zones))
  } else {
    zones$STATE_ZONE <- as.character(zones$STATE_ZONE)
  }
  if (nrow(zones) == 0) {
    cache_put("reference", "wi_public_zones", zones, ttl_seconds = 24 * 3600)
    return(zones)
  }
  zones$STATE_ZONE <- toupper(zones$STATE_ZONE)
  cache_put("reference", "wi_public_zones", zones, ttl_seconds = 24 * 3600)
  zones
}

# Why: zone-scoped alerts ("WIZ020") need to project onto every ZIP whose
# polygon meaningfully overlaps the zone, not just the ZIPs whose centroid
# happens to fall inside; we precompute the mapping once.
# How: for each ZIP, takes the intersection of polygon-hits and centroid-
# hits — a centroid hit always counts; otherwise we measure the area
# overlap between zip and zone polygon and only include the pair when
# overlap >= min_overlap of the zip area.
# What: returns a named list keyed by STATE_ZONE whose values are
# character vectors of zipcodes covered by that zone.
# When: called by zone_alerts.R on the first alert payload of each session
# and cached for 24h thereafter (invalidated when the zone shapefile or
# ZCTA reference is rebuilt).
# Impact: min_overlap controls the precision/recall trade — too low and a
# zone bleeds into ZIPs it barely touches, too high and small ZIPs near a
# zone boundary get dropped from coverage.
get_zone_zip_lookup <- function(min_overlap = 0.15) {
  cache_name <- sprintf("zone_zip_lookup_%0.2f", min_overlap)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)

  zones <- load_public_zones()
  if (nrow(zones) == 0) {
    cache_put("derived", cache_name, list(), ttl_seconds = 24 * 3600)
    return(list())
  }

  zips_proj <- suppressWarnings(sf::st_transform(wi_zctas, 5070))
  zones_proj <- suppressWarnings(sf::st_transform(zones, 5070))
  zip_pts <- suppressWarnings(sf::st_transform(point_on_surface_lonlat(wi_zctas), 5070))
  zip_areas <- as.numeric(sf::st_area(zips_proj))
  poly_hits <- sf::st_intersects(zips_proj, zones_proj)
  point_hits <- sf::st_intersects(zip_pts, zones_proj)

  lookup <- setNames(vector("list", nrow(zones)), zones$STATE_ZONE)

  for (i in seq_len(nrow(zips_proj))) {
    candidate <- unique(c(poly_hits[[i]], point_hits[[i]]))
    if (length(candidate) == 0) next
    for (j in candidate) {
      include <- j %in% point_hits[[i]]
      if (!include && j %in% poly_hits[[i]]) {
        overlap_geom <- tryCatch(
          suppressWarnings(sf::st_intersection(zips_proj[i, ], zones_proj[j, ])),
          error = function(e) NULL
        )
        overlap_ratio <- 0
        if (!is.null(overlap_geom) && nrow(overlap_geom) > 0) {
          overlap_ratio <- sum(as.numeric(sf::st_area(overlap_geom))) / max(zip_areas[i], 1e-9)
        }
        include <- is.finite(overlap_ratio) && overlap_ratio >= min_overlap
      }
      if (include) {
        zone_id <- zones$STATE_ZONE[j]
        lookup[[zone_id]] <- unique(c(lookup[[zone_id]], as.character(wi_zctas$zipcode[i])))
      }
    }
  }

  cache_put("derived", cache_name, lookup, ttl_seconds = 24 * 3600)
  lookup
}

# Why: the data shape needs to change between two pipeline stages and
# centralising the split/join keeps schema invariants in one place.
# What: Splits a pipe-delimited code string (NWS alert UGC / SAME / zone
# fields use this format) into a unique trimmed character vector; returns
# character(0) on NULL / NA / empty input.
# How: cache lookup + put + row/element loop + named vector build.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
split_pipe_codes <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x) || !nzchar(trimws(x))) return(character(0))
  vals <- unlist(strsplit(as.character(x), "|", fixed = TRUE), use.names = FALSE)
  vals <- trimws(as.character(vals))
  unique(vals[nzchar(vals)])
}

# Why: downstream callers need this lookup encapsulated so cache + fallback
# handling lives in one place.
# What: Returns a list(by_geoid, name_to_geoid) where by_geoid maps each WI
# county GEOID to its zipcodes and name_to_geoid maps lowercase county
# names to GEOID — used by alert ingest to resolve county-scoped SAME / UGC
# codes onto ZIPs.
# How: cache lookup + put + row/element loop + named vector build.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
get_county_zip_lookup <- function() {
  cached <- cache_get("derived", "county_zip_lookup")
  if (!is.null(cached)) return(cached)
  by_geoid <- split(wi_zctas$zipcode, wi_zctas$county_geoid)
  by_geoid <- lapply(by_geoid, function(x) unique(as.character(stats::na.omit(x))))
  valid_geoids <- unique(stats::na.omit(as.character(wi_counties$GEOID)))
  by_geoid <- by_geoid[names(by_geoid) %in% valid_geoids]
  name_to_geoid <- setNames(as.character(wi_counties$GEOID), tolower(as.character(wi_counties$NAME)))
  out <- list(by_geoid = by_geoid, name_to_geoid = name_to_geoid)
  cache_put("derived", "county_zip_lookup", out, ttl_seconds = 24 * 3600)
  out
}

# Why: downstream callers need this lookup encapsulated so cache + fallback
# handling lives in one place.
# What: Returns the cached zone -> county-list lookup populated lazily by
# update_zone_county_lookup as alerts arrive; an empty list on first read.
# How: cache lookup + put.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
get_zone_county_lookup <- function() {
  cached <- cache_get("derived", "zone_county_lookup")
  if (!is.null(cached)) return(cached)
  list()
}

# Why: NWS alerts arrive with both UGC zone codes (WIZ020) and SAME county
# codes; once we observe a zone-county pairing we want to remember it so
# later alerts that only carry a zone code can still resolve to counties.
# What: returns the merged lookup; side-effect updates the cached version.
# How: deep-merges new_map's zone -> counties pairs into the existing
# lookup (uniquing the value lists), and caches for 24h.
# When: called by zone_alerts.R / learn_zone_counties_from_geometry whenever
# an alert provides both pieces of information at the same time.
# Impact: the lookup is purely additive within a session; if a zone gets
# remapped to a different county set, the old entries persist until cache
# TTL expiry — currently this is acceptable because zones rarely move.
update_zone_county_lookup <- function(new_map) {
  if (length(new_map) == 0) return(get_zone_county_lookup())
  lookup <- get_zone_county_lookup()
  for (nm in names(new_map)) {
    existing <- lookup[[nm]] %||% character(0)
    lookup[[nm]] <- unique(c(as.character(existing), as.character(new_map[[nm]])))
  }
  cache_put("derived", "zone_county_lookup", lookup, ttl_seconds = 24 * 3600)
  lookup
}
