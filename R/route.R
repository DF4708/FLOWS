# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/route.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Normalises a freeform location query for matching against place /
# county names — strips state qualifiers ("Wisconsin", "WI"), drops
# trailing place-type suffixes ("County", "City", "Town", "Village"), and
# collapses whitespace; output is what resolve_search_query compares
# against the precomputed normalised place / county name vectors.
# How: regex match + sf geometry op.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_location_query_text <- function(x) {
  txt <- normalize_match_text(x)
  txt <- gsub("\\b(state of )?wisconsin\\b", " ", txt, perl = TRUE)
  txt <- gsub("\\bwi\\b", " ", txt, perl = TRUE)
  txt <- trimws(gsub("\\s+", " ", txt, perl = TRUE))
  txt <- gsub("\\b(county|city|town|village)\\b$", " ", txt, perl = TRUE)
  trimws(gsub("\\s+", " ", txt, perl = TRUE))
}

# Why: users type freeform location queries (a city name, a ZIP code, a county
# name) and the routing pipeline needs an authoritative spatial geometry plus
# the set of ZIPs that geometry covers.
# What: returns a list with type ("zip"/"city"/"county"), a unioned sf geometry,
# and a vector of zipcodes - or NULL if nothing matches.
# How: scans for a 5-digit ZIP token first, falls back to a normalised string
# match against place names and county names; "county" suffix in the query
# biases toward the county table over the place table.
# When: called by resolve_search_point at the top of plan_route_options for
# both the start and end of a route request.
# Impact: a wrong match here cascades into every downstream stage - a missed
# city becomes a ZIP-fallback search that lands on a county centroid, which
# is what motivated find_polygon_or_point_nodes in the pathfinder.
resolve_search_query <- function(query) {
  q_raw <- trimws(query %||% "")
  q <- normalize_location_query_text(q_raw)
  if (!nzchar(q)) return(NULL)
  zip_token <- regmatches(q_raw, regexpr("\\b[0-9]{5}\\b", q_raw, perl = TRUE))
  zip_match <- wi_zctas[wi_zctas$zipcode == zip_token, , drop = FALSE]
  if (nrow(zip_match) == 0 && grepl("^[0-9]+$", q)) zip_match <- wi_zctas[grepl(paste0("^", q), wi_zctas$zipcode), , drop = FALSE]
  if (nrow(zip_match) > 0) return(list(type = "zip", geometry = sf::st_union(zip_match), zipcodes = zip_match$zipcode))
  places <- load_places()
  place_names <- normalize_location_query_text(places$NAME)
  county_names <- normalize_location_query_text(wi_counties$NAME)
  prefer_county <- grepl("\\bcounty\\b", normalize_match_text(q_raw), perl = TRUE)
  match_places <- function() {
    place_match <- places[place_names == q, , drop = FALSE]
    if (nrow(place_match) == 0) place_match <- places[grepl(q, place_names, fixed = TRUE), , drop = FALSE]
    if (nrow(place_match) == 0) return(NULL)
    hits <- sf::st_intersects(wi_zctas, place_match)
    zipcodes <- wi_zctas$zipcode[lengths(hits) > 0]
    list(type = "city", geometry = sf::st_union(place_match), zipcodes = unique(zipcodes))
  }
  match_counties <- function() {
    county_match <- wi_counties[county_names == q, , drop = FALSE]
    if (nrow(county_match) == 0) county_match <- wi_counties[grepl(q, county_names, fixed = TRUE), , drop = FALSE]
    if (nrow(county_match) == 0) return(NULL)
    zipcodes <- wi_zctas$zipcode[wi_zctas$county_name %in% county_match$NAME]
    list(type = "county", geometry = sf::st_union(county_match), zipcodes = unique(zipcodes))
  }
  if (isTRUE(prefer_county)) {
    county_res <- match_counties()
    if (!is.null(county_res)) return(county_res)
    place_res <- match_places()
    if (!is.null(place_res)) return(place_res)
  } else {
    place_res <- match_places()
    if (!is.null(place_res)) return(place_res)
    county_res <- match_counties()
    if (!is.null(county_res)) return(county_res)
  }
  NULL
}

# Why: callers (plan_route_options, the geocoder UI) need a single object that
# bundles a freeform location query's spatial geometry with the lon/lat point
# the routing engine should actually snap to.
# What: returns a list(type, label, geometry, point, lon, lat, zipcodes) for
# the query, or NULL when the query cannot be resolved to a Wisconsin place.
# How: delegates the matching to resolve_search_query, then computes a
# point-on-surface for the resulting (possibly multi-polygon) geometry so the
# anchor point lies inside the polygon even for L-shaped counties.
# When: called twice per plan_route_options call (once each for start_query
# and end_query), and from any other UI surface that needs to anchor to a
# user-typed Wisconsin location.
# Impact: a NULL return aborts the route plan with a "could not be resolved"
# message; using point_on_surface_lonlat (rather than st_centroid) avoids
# anchor points that fall outside concave geometries.
resolve_search_point <- function(query) {
  res <- resolve_search_query(query)
  if (is.null(res)) return(NULL)
  geom_sfc <- if (inherits(res$geometry, "sfc")) res$geometry else sf::st_sfc(res$geometry, crs = 4326)
  geom_sf <- sf::st_sf(id = 1L, geometry = geom_sfc)
  pt <- point_on_surface_lonlat(geom_sf)
  coords <- suppressWarnings(sf::st_coordinates(pt))
  if (is.null(coords) || nrow(coords) == 0) return(NULL)
  list(
    type = res$type,
    label = trimws(as.character(query %||% "")),
    geometry = geom_sf,
    point = pt,
    lon = as.numeric(coords[1, "X"]),
    lat = as.numeric(coords[1, "Y"]),
    zipcodes = unique(as.character(res$zipcodes %||% character(0)))
  )
}


# Why: per-segment risk reasons arrive as freeform text from WisDOT 511 and the
# NWS road-impacted alerts, but the route summary, popup, and overlay legend
# all need a small, fixed taxonomy so we can group, count, and colour them.
# What: returns one of "winter" / "closure" / "delay" / "alert" / "incident" /
# "message sign" / "official" / "none", picked by keyword match against the
# combined source_text and reason_text.
# How: lowercases and concatenates the two inputs, then walks an ordered list
# of regex tests; the first match wins, so more specific bucket names (winter,
# closure) come before catch-alls (incident, official).
# When: invoked per segment by build_route_segments when an official cause
# field is missing, and per route by summarize_official_transport_causes when
# rolling up the cause histogram for the UI.
# Impact: changing the keyword set shifts how routes get badged in the popup
# and the route-summary causes line; misordering buckets can hide a closure
# under a generic "incident" label.
classify_official_transport_cause <- function(reason_text = "", source_text = "") {
  txt <- tolower(paste(source_text, reason_text, collapse = " | "))
  if (!nzchar(trimws(txt))) return("none")
  if (grepl("message sign|vms", txt)) return("message sign")
  if (grepl("winter", txt) || grepl("snow|ice|slippery|covered|blowing snow|reduced visibility|fog", txt)) return("winter")
  if (grepl("closed|closure|blocked|impassable|detour|washout|bridge|sinkhole", txt)) return("closure")
  if (grepl("delay|travel time|congestion|slow traffic", txt)) return("delay")
  if (grepl("alert", txt)) return("alert")
  if (grepl("crash|incident|disabled|hazmat|jackknife|fire|event", txt)) return("incident")
  "official"
}

# Why: the route popup needs a one-line summary of which official cause kinds
# are present along the route, ranked by frequency, so the driver sees the
# dominant disruption (e.g. "winter x12; closure x3") instead of a long list.
# What: returns a single character string like "<kind> x<count>; ..." plus an
# optional "Sources: ..." tail, or NA_character_ if no real causes are seen.
# How: drops empty/"none" entries, tabulates the rest, sorts descending by
# count, and trims to max_items; appends up to three unique source labels at
# the end when source_vec is provided.
# When: called once per built route when assembling the route summary for
# render_route_summary_ui and render_route_details_ui.
# Impact: max_items controls how busy the popup line gets; raising it can
# make the summary feel noisy on routes that touch many small incidents.
summarize_official_transport_causes <- function(cause_vec, source_vec = character(0), max_items = 3L) {
  cause_vec <- as.character(cause_vec %||% character(0))
  cause_vec <- cause_vec[nzchar(trimws(cause_vec)) & cause_vec != "none"]
  if (length(cause_vec) == 0) return(NA_character_)
  tab <- sort(table(cause_vec), decreasing = TRUE)
  parts <- sprintf("%s x%d", names(tab), as.integer(tab))
  source_vec <- unique(as.character(source_vec %||% character(0)))
  source_vec <- source_vec[nzchar(trimws(source_vec))]
  source_part <- if (length(source_vec) > 0) sprintf("Sources: %s.", paste(utils::head(source_vec, 3L), collapse = ", ")) else ""
  paste(trimws(paste(utils::head(parts, max_items), collapse = "; ")), source_part)
}

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Maps a freeform reason_text to a numeric closure penalty (8 for
# hard closures, 3 for incidents/restrictions, 0 otherwise) used as an
# additive cost-multiplier in the routing edge weights.
# How: regex match.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_closure_penalty <- function(reason_text = "") {
  txt <- tolower(trimws(as.character(reason_text %||% "")))
  if (!nzchar(txt)) return(0)
  if (grepl("closed|closure|blocked|impassable|collapse|washout", txt)) return(8)
  if (grepl("detour|restriction|lane blocked|incident|event", txt)) return(3)
  0
}

# Profile-keyed lookup tables. Defined once at source time so callers can do a
# single vectorised tier->value lookup instead of one R-level function call per
# edge (the prior vapply was the largest hot spot when graph size grew to ~97k
# OSM ways). The scalar wrappers below preserve the legacy signatures.
ROUTE_TIER_SPEED_TABLES <- list(
  fastest   = c(Interstate = 72, US = 54, State = 42, County = 34, Major = 30, Primary = 28, Secondary = 24, Connector = 18),
  safest    = c(Interstate = 66, US = 50, State = 40, County = 34, Major = 30, Primary = 28, Secondary = 24, Connector = 17),
  metro     = c(Interstate = 74, US = 56, State = 44, County = 30, Major = 28, Primary = 26, Secondary = 22, Connector = 17),
  metrorail = c(Interstate = 74, US = 56, State = 44, County = 30, Major = 28, Primary = 26, Secondary = 22, Connector = 17)
)

ROUTE_TIER_BONUS_TABLES <- list(
  # Fastest: all-1.0 makes the cost function reduce to pure length/speed
  # (i.e., physical drive minutes). Adding any tier preference here would let
  # the planner pick a longer Interstate path over a shorter US/State path
  # that is actually faster, breaking the "Fastest is fastest" invariant.
  fastest   = c(Interstate = 1.00, US = 1.00, State = 1.00, County = 1.00, Major = 1.00, Primary = 1.00, Secondary = 1.00, Connector = 1.0),
  # Safest: also all-1.0. The Safest profile must lex-prioritise low risk over
  # tier preference, so any per-tier discount (especially for Interstate) lets
  # a higher-risk highway out-cost a lower-risk surface route despite the alpha
  # penalty. Risk avoidance is expressed via the alpha multiplier alone; the
  # post-hoc safest_time_cap_multiplier still bounds the absolute drive time.
  safest    = c(Interstate = 1.00, US = 1.00, State = 1.00, County = 1.00, Major = 1.00, Primary = 1.00, Secondary = 1.00, Connector = 1.0),
  metro     = c(Interstate = 0.38, US = 0.54, State = 0.72, County = 1.16, Major = 1.24, Primary = 1.14, Secondary = 1.40, Connector = 1.0),
  metrorail = c(Interstate = 0.38, US = 0.54, State = 0.72, County = 1.16, Major = 1.24, Primary = 1.14, Secondary = 1.40, Connector = 1.0)
)

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Vectorised tier->mph lookup for a profile. Unknown tiers fall back
# to 28 mph (the historical default in the scalar wrapper).
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_tier_speed_lookup <- function(route_tier, route_key = "fastest") {
  key <- tolower(as.character(route_key %||% "fastest"))
  tbl <- ROUTE_TIER_SPEED_TABLES[[key]] %||% ROUTE_TIER_SPEED_TABLES$fastest
  speed <- suppressWarnings(as.numeric(tbl[as.character(route_tier)]))
  speed[!is.finite(speed) | speed <= 0] <- 28
  speed
}

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Vectorised tier->bonus lookup for a profile. Unknown tiers fall
# back to 1.0.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_tier_bonus_lookup <- function(route_tier, route_key = "fastest") {
  key <- tolower(as.character(route_key %||% "fastest"))
  tbl <- ROUTE_TIER_BONUS_TABLES[[key]] %||% ROUTE_TIER_BONUS_TABLES$fastest
  bonus <- suppressWarnings(as.numeric(tbl[as.character(route_tier)]))
  bonus[!is.finite(bonus) | bonus <= 0] <- 1
  bonus
}

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Scalar wrapper around route_tier_speed_lookup — kept for
# backwards-compatibility with call sites that pass a single tier instead
# of a vector.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_tier_speed_for_profile <- function(route_tier = "", route_key = "fastest") {
  tier <- as.character(route_tier %||% "Secondary")
  unname(route_tier_speed_lookup(tier, route_key))[1]
}

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Scalar wrapper around route_tier_bonus_lookup; falls back to
# "Primary" or "Secondary" tier based on road_class when no explicit tier
# is supplied.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_tier_bonus_for_profile <- function(route_tier = "", route_key = "fastest", road_class = "") {
  tier <- as.character(route_tier %||% ifelse(identical(as.character(road_class %||% ""), "Primary"), "Primary", "Secondary"))
  unname(route_tier_bonus_lookup(tier, route_key))[1]
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns base_speed_mph clipped to a minimum of 10 mph, with a 5 mph
# penalty applied to any segment whose risk exceeds RISK_RED_MIN — used
# when computing per-segment ETA.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
adjusted_route_speed_mph <- function(base_speed_mph, segment_risk = 0) {
  speed <- suppressWarnings(as.numeric(base_speed_mph))
  speed[!is.finite(speed) | speed <= 0] <- 28
  risk <- pmax(0, pmin(1, suppressWarnings(as.numeric(segment_risk))))
  risk[!is.finite(risk)] <- 0
  speed[risk > RISK_RED_MIN] <- speed[risk > RISK_RED_MIN] - 5
  pmax(10, speed)
}

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Predicate: TRUE when route_tier is one of Interstate / US / State
# (the high-tier corridors used by route_highway_summary to compute
# pre/post-highway mileage splits).
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_high_priority_tier <- function(route_tier = "") {
  as.character(route_tier %||% "") %in% c("Interstate", "US", "State")
}

# Why: constructor/factory for a stable internal type used across the
# layer.
# What: Builds a stable graph node ID by snapping projected (x, y) meter
# coordinates to a ROUTE_NODE_SNAP_METERS grid — two endpoints within
# snap_m of each other share an ID, which is how OSM ways with slightly
# different junction coordinates get joined into a single graph node.
# How: sf geometry op + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
make_route_node_id <- function(x, y, snap_m = ROUTE_NODE_SNAP_METERS) {
  snap_m <- max(1, suppressWarnings(as.numeric(snap_m %||% ROUTE_NODE_SNAP_METERS)))
  sprintf("%d|%d", round(as.numeric(x) / snap_m), round(as.numeric(y) / snap_m))
}

# Why: the OSM road set has ~97k drivable ways; A* needs a flat data.frame of
# routable edges with risk, closure penalty, tier, and endpoint coordinates so
# the graph build can run vectorised passes instead of per-row loops.
# What: returns a data.frame (one row per OSM way, projected EPSG:5070) with
# from/to node IDs, length_m, segment_risk, closure_penalty, route_tier, and
# the supporting columns needed by build_route_graph and the cost functions.
# How: loads cached WI roads, joins risk scores from build_modeled_road_risk_index
# (or a roads_overlay if provided), extracts first/last vertex of each linestring
# in one vectorised pass, then snaps endpoints to ROUTE_NODE_SNAP_METERS to form
# graph node IDs. Result is cached by render signature so subsequent calls are
# instant.
# When: called inside plan_route_options before native_plan_routes; result is
# also cached at the top of the routing module.
# Impact: the most expensive step on a cold cache (~30-90s for OSM-scale data),
# so its cache key fidelity is critical - any change to inputs that affects
# segment risk must be reflected in cache_payload.
build_route_segments <- function(zips, horizon_key = "live", roads_overlay = NULL) {
  overlay_payload <- NULL
  if (!is.null(roads_overlay) && inherits(roads_overlay, "sf") && nrow(roads_overlay) > 0) {
    overlay_fields <- intersect(c("road_id", "driving_total_risk", "driving_reason_text", "road_source", "official_cause_text", "road_class", "route_tier", "base_speed_mph"), names(roads_overlay))
    if (length(overlay_fields) > 0) {
      overlay_df <- sf::st_drop_geometry(roads_overlay[, overlay_fields, drop = FALSE])
      overlay_df <- overlay_df[order(overlay_df$road_id), , drop = FALSE]
      # Columnwise vectorised paste (was apply(df,1,paste) — a per-row R loop
      # ~3.7x slower over ~100k roads, ~1s, paid on every warm incl. cache
      # hits). This is a cache KEY: only determinism + collision-resistance
      # matter, not byte-identity, so the numeric-format change vs apply/
      # as.matrix is harmless (one-time cache rebuild). Benchmark cycle 19.
      overlay_payload <- paste(do.call(paste, c(as.list(overlay_df), sep = "~")), collapse = "|")
    }
  }
  cache_fields <- intersect(c("zipcode", "render_signature", "driving_total_risk", "normalized_risk_score"), names(zips))
  cache_payload <- if (nzchar(overlay_payload %||% "")) {
    paste(horizon_key, overlay_payload, sep = "|")
  } else if (length(cache_fields) > 0 && nrow(zips) > 0) {
    paste(
      do.call(paste, c(as.list(sf::st_drop_geometry(zips[, cache_fields, drop = FALSE])), sep = "~")),
      collapse = "|"
    )
  } else {
    horizon_key
  }
  # v4 adds boundary_distance_m (perimeter-aware risk attenuation).
  cache_name <- paste0("route-segments-v4-", horizon_key, "-", cache_hash_string(cache_payload))
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)

  return(flows_time_step(
    sprintf("build_route_segments cold body (%s)", horizon_key),
    build_route_segments_cold(zips, horizon_key, roads_overlay, cache_name),
    group = "route"
  ))
}

# Why: a downstream consumer needs the assembled output in a single call
# rather than calling the underlying primitives separately.
# What: Cold-cache body of build_route_segments — extracted so the wrapper
# above can time it without confusing the early-return cache path.
# How: sf geometry op + named vector build + guarded numeric coercion.
# When: called by the layer's top-level builder when assembling the
# user-visible output.
# Impact: any new column or row source needs to be added here AND in the
# layer's standardise_* schema; mismatched schemas show up as silent column
# drops downstream.
build_route_segments_cold <- function(zips, horizon_key, roads_overlay, cache_name) {
  roads <- load_wi_roads()
  if (nrow(roads) == 0) return(data.frame())
  roads <- suppressWarnings(sf::st_cast(roads, "LINESTRING", warn = FALSE))
  roads <- ensure_crs_4326(roads)
  if (!is.null(roads_overlay) && inherits(roads_overlay, "sf") && nrow(roads_overlay) > 0) {
    overlay <- standardize_road_overlay_sf(roads_overlay)
    overlay_match <- match(roads$road_id, overlay$road_id)
    overlay_risk <- suppressWarnings(as.numeric(overlay$driving_total_risk[overlay_match]))
    overlay_risk[!is.finite(overlay_risk)] <- 0
    overlay_reason <- as.character(overlay$driving_reason_text[overlay_match])
    overlay_reason[is.na(overlay_reason)] <- ""
    overlay_source <- as.character(overlay$road_source[overlay_match])
    overlay_source[is.na(overlay_source)] <- ""
    overlay_cause <- as.character(overlay$official_cause_text[overlay_match])
    overlay_cause[is.na(overlay_cause) | !nzchar(trimws(overlay_cause))] <- "none"
    risk_scores <- stats::setNames(overlay_risk, roads$road_id)
    risk_reasons <- stats::setNames(overlay_reason, roads$road_id)
    risk_sources <- stats::setNames(overlay_source, roads$road_id)
    risk_causes <- stats::setNames(overlay_cause, roads$road_id)
  } else {
    lookup <- load_road_zip_lookup()
    road_risk <- build_modeled_road_risk_index(roads, lookup, zips)
    risk_scores <- stats::setNames(road_risk$driving_total_risk, road_risk$road_id)
    risk_reasons <- stats::setNames(as.character(road_risk$driving_reason_text), road_risk$road_id)
    risk_sources <- stats::setNames(as.character(road_risk$road_source), road_risk$road_id)
    risk_causes <- stats::setNames(as.character(road_risk$official_cause_text), road_risk$road_id)
  }

  # Vectorised build: extract first/last endpoint and total length per linestring
  # using one pass over the projected coordinate matrix; all downstream fields
  # are computed columnwise. This replaces a per-row R loop that was O(n)
  # data.frame() calls — important now that the OSM road set has ~100k ways.
  roads_proj <- suppressWarnings(sf::st_transform(roads, 5070))
  coords_proj <- suppressWarnings(sf::st_coordinates(roads_proj))
  if (is.null(coords_proj) || nrow(coords_proj) == 0) return(data.frame())
  L1 <- if ("L1" %in% colnames(coords_proj)) as.integer(coords_proj[, "L1"]) else rep(1L, nrow(coords_proj))
  X <- coords_proj[, "X"]
  Y <- coords_proj[, "Y"]
  n_roads <- nrow(roads)

  # First / last vertex per linestring (L1 indexes the road row). Use length(L1)
  # rather than n_roads because the coordinate matrix has more rows than roads.
  n_coords <- length(L1)
  first_pos <- match(seq_len(n_roads), L1)
  last_pos <- n_coords + 1L - match(seq_len(n_roads), rev(L1))
  start_x <- X[first_pos]; start_y <- Y[first_pos]
  end_x <- X[last_pos]; end_y <- Y[last_pos]

  # Total length per line: vectorised. Use sf::st_length on the projected sf for
  # numerical robustness (it handles multi-segment linestrings exactly).
  length_m <- as.numeric(suppressWarnings(sf::st_length(roads_proj)))

  road_id <- as.character(roads$road_id %||% paste0("road-", seq_len(n_roads)))
  seg_risk <- suppressWarnings(as.numeric(risk_scores[road_id]))
  seg_risk[!is.finite(seg_risk)] <- 0

  # Perimeter-aware risk decay input: distance from each segment's centroid
  # (in projected meters) to the union of "lower-risk" ZIPs. compute_profile_
  # edge_weights uses this to apply an exponential attenuation, so a road
  # hugging the edge of a green ZIP inside a yellow polygon gets a smaller
  # effective risk than one in the core of the same yellow polygon.
  boundary_distance_m <- rep(.Machine$double.xmax, n_roads)
  if (!is.null(zips) && "normalized_risk_score" %in% names(zips) && nrow(zips) > 0) {
    risk_score_vec <- suppressWarnings(as.numeric(zips$normalized_risk_score))
    low_risk_idx <- which(is.finite(risk_score_vec) & risk_score_vec < RISK_GREEN_MIN)
    if (length(low_risk_idx) > 0) {
      low_risk_proj <- tryCatch(
        suppressWarnings(sf::st_transform(zips[low_risk_idx, , drop = FALSE], sf::st_crs(roads_proj))),
        error = function(e) NULL
      )
      if (!is.null(low_risk_proj)) {
        low_risk_union <- tryCatch(
          suppressWarnings(sf::st_union(sf::st_geometry(low_risk_proj))),
          error = function(e) NULL
        )
        if (!is.null(low_risk_union)) {
          midpoints_proj <- tryCatch(
            suppressWarnings(sf::st_centroid(sf::st_geometry(roads_proj))),
            error = function(e) NULL
          )
          if (!is.null(midpoints_proj) && length(midpoints_proj) == n_roads) {
            d_mat <- tryCatch(
              suppressWarnings(sf::st_distance(midpoints_proj, low_risk_union)),
              error = function(e) NULL
            )
            if (!is.null(d_mat) && length(d_mat) == n_roads) {
              boundary_distance_m <- as.numeric(d_mat)
              boundary_distance_m[!is.finite(boundary_distance_m) | boundary_distance_m < 0] <- 0
            }
          }
        }
      }
    }
  }

  official_reason <- as.character(risk_reasons[road_id])
  official_reason[is.na(official_reason)] <- ""
  reason_text <- ifelse(nzchar(trimws(official_reason)), official_reason, "All clear.")
  official_source <- as.character(risk_sources[road_id])
  official_source[is.na(official_source)] <- ""
  official_cause_kind <- as.character(risk_causes[road_id])
  needs_classify <- is.na(official_cause_kind) | !nzchar(official_cause_kind)
  if (any(needs_classify)) {
    official_cause_kind[needs_classify] <- vapply(
      seq_len(sum(needs_classify)),
      function(i) classify_official_transport_cause(official_reason[needs_classify][i],
                                                    official_source[needs_classify][i]),
      character(1)
    )
  }

  # Vectorised closure penalty: 8 for hard closures, 3 for incidents, else 0.
  closure_pen <- rep(0, n_roads)
  txt <- tolower(trimws(official_reason))
  closure_pen[grepl("closed|closure|blocked|impassable|collapse|washout", txt)] <- 8
  mid <- closure_pen == 0 & grepl("detour|restriction|lane blocked|incident|event", txt)
  closure_pen[mid] <- 3

  route_tier <- as.character(roads$route_tier %||% ifelse(roads$road_class == "Primary", "Primary", "Secondary"))
  road_class <- as.character(roads$road_class %||% "Road")
  road_name <- as.character(roads$road_name %||% "Wisconsin road")
  base_speed_mph <- suppressWarnings(as.numeric(roads$base_speed_mph))
  fallback_speed <- vapply(route_tier, route_tier_speed_for_profile, numeric(1), route_key = "fastest")
  base_speed_mph[!is.finite(base_speed_mph) | base_speed_mph <= 0] <- fallback_speed[!is.finite(base_speed_mph) | base_speed_mph <= 0]
  weight <- (length_m / base_speed_mph) * (1 + 4.0 * seg_risk + closure_pen)

  keep <- is.finite(start_x) & is.finite(start_y) & is.finite(end_x) & is.finite(end_y) &
          is.finite(length_m) & length_m > 0
  if (!any(keep)) return(data.frame())

  out <- data.frame(
    edge_id = cumsum(as.integer(keep))[keep],
    segment_index = seq_len(n_roads)[keep],
    road_id = road_id[keep],
    road_name = road_name[keep],
    road_class = road_class[keep],
    route_tier = route_tier[keep],
    base_speed_mph = base_speed_mph[keep],
    from_node = make_route_node_id(start_x[keep], start_y[keep]),
    to_node = make_route_node_id(end_x[keep], end_y[keep]),
    from_x = start_x[keep], from_y = start_y[keep],
    to_x = end_x[keep], to_y = end_y[keep],
    length_m = length_m[keep],
    edge_weight = weight[keep],
    segment_risk = seg_risk[keep],
    boundary_distance_m = boundary_distance_m[keep],
    closure_penalty = closure_pen[keep],
    reason_text = reason_text[keep],
    official_reason_text = official_reason[keep],
    official_source = official_source[keep],
    official_cause_kind = official_cause_kind[keep],
    stringsAsFactors = FALSE
  )
  cache_put(
    "derived",
    cache_name,
    out,
    ttl_seconds = if (identical(horizon_key, "live")) max(600L, ALERT_TTL_SECONDS) else FORECAST_TTL_SECONDS
  )
  out
}

# Why: A* needs more than just the single nearest node to a query point —
# starting from one node can force the search down a local street even when
# a high-tier road is close by; a small candidate set lets the planner
# pick the best entry node by total cost.
# What: returns up to max_candidates node_ids ordered by distance to point,
# preferring nodes from preferred_node_ids when supplied.
# How: ranks preferred_node_ids by squared distance, then fills any
# remaining slots from node_df overall; deduplicates and trims to the cap.
# When: called by find_polygon_or_point_nodes / native_plan_routes when
# building the candidate cross-product for a single A* / cppRouting search.
# Impact: too few candidates can hide the best entry node; too many blows up
# the cppr_best_path cartesian product (cost grows as src x dst).
find_candidate_route_nodes <- function(node_df, point, preferred_node_ids = NULL, max_candidates = 6L) {
  if (is.null(node_df) || nrow(node_df) == 0 || is.null(point)) return(character(0))
  pt <- sf::st_sfc(sf::st_point(c(point$lon, point$lat)), crs = 4326)
  pt_proj <- suppressWarnings(sf::st_transform(pt, 5070))
  coords <- suppressWarnings(sf::st_coordinates(pt_proj))
  if (is.null(coords) || nrow(coords) == 0) return(character(0))

  rank_nodes <- function(df) {
    if (is.null(df) || nrow(df) == 0) return(character(0))
    dx <- df$x - coords[1, "X"]
    dy <- df$y - coords[1, "Y"]
    d2 <- dx * dx + dy * dy
    keep <- which(!is.na(d2))                 # order(na.last=NA) drops NAs
    if (length(keep) == 0) return(character(0))
    # We only need the max_candidates nearest DISTINCT node_ids. Partial-select
    # a window (O(n)) sized to cover typical duplication, then dedup; fall back
    # to the exact full order() only if heavy duplication left too few distinct.
    # Byte-identical to the prior full-sort form (fallback guarantees it), but
    # O(n) instead of O(n log n) in the common case (node_ids ~distinct).
    k <- min(length(keep), max(max_candidates * 4L, 8L))
    sel <- k_smallest_indices(d2[keep], k)
    ids <- unique(df$node_id[keep[sel]])
    if (length(ids) >= max_candidates || k >= length(keep)) {
      return(ids[seq_len(min(length(ids), max_candidates))])
    }
    ord <- order(d2, na.last = NA)
    u <- unique(df$node_id[ord])
    u[seq_len(min(length(u), max_candidates))]
  }

  preferred <- if (!is.null(preferred_node_ids) && length(preferred_node_ids) > 0) node_df[node_df$node_id %in% preferred_node_ids, , drop = FALSE] else node_df[0, , drop = FALSE]
  ids <- rank_nodes(preferred)
  if (length(ids) < max_candidates) {
    extra <- rank_nodes(node_df)
    ids <- unique(c(ids, extra))
  }
  ids[seq_len(min(length(ids), max_candidates))]
}


# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Returns the human-readable description of a routing profile
# (fastest / safest / metro / metrorail) shown in the route details panel —
# kept aligned with the route-selection contract documented in global.R.
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_behavior_description <- function(route_key = "fastest") {
  key <- tolower(as.character(route_key %||% "fastest"))
  switch(
    key,
    fastest = "Shortest-time route that gets onto the main highway corridor as early as practical, stays on it until the final stretch, and accepts higher risk when that is still the quickest path.",
    safest = "Lowest-risk route that prefers transparent over green, green over yellow, and avoids red entirely when possible. It stays within the same 50% time ceiling as the other alternatives and uses low-risk detours instead of metro hub routing.",
    metrorail = "Hub-based route that stays within the same 50% time ceiling while following city-to-city highway corridors and passing near developed hubs instead of detouring into each downtown center.",
    metro = "Hub-based route that stays within the same 50% time ceiling while following city-to-city highway corridors and passing near developed hubs instead of detouring into each downtown center.",
    "Risk-aware Wisconsin route."
  )
}


# Why: the routing engine emits internal connector edges (origin / destination
# stubs) and zero-length artefacts that are useful for cost accounting but
# would clutter the rendered map line.
# What: returns route_sf with connector edges, zero-length segments, and
# duplicate consecutive (road_id, segment_index) rows removed.
# How: ANDs together a series of column-aware predicates (route_connector,
# road_class != "Connector", road_name not "Origin/Destination", length > 1m)
# then dedupes consecutive identical edge keys.
# When: invoked by build_route_display_sf and route_display_sf before any
# rendering or stitching step.
# Impact: aggressively filtering here is what keeps the rendered path clean,
# but dropping a real edge by mistake (e.g. mislabelling road_class) leaves
# a visible gap in the route line.
filter_display_route_sf <- function(route_sf) {
  if (is.null(route_sf) || nrow(route_sf) == 0) return(route_sf)
  keep <- rep(TRUE, nrow(route_sf))
  if ("route_connector" %in% names(route_sf)) {
    keep <- keep & !(route_sf$route_connector %in% TRUE)
  }
  if ("road_class" %in% names(route_sf)) {
    keep <- keep & as.character(route_sf$road_class %||% "") != "Connector"
  }
  if ("route_tier" %in% names(route_sf)) {
    keep <- keep & as.character(route_sf$route_tier %||% "") != "Connector"
  }
  if ("official_cause_kind" %in% names(route_sf)) {
    keep <- keep & as.character(route_sf$official_cause_kind %||% "") != "connector"
  }
  if ("road_name" %in% names(route_sf)) {
    keep <- keep & !(trimws(as.character(route_sf$road_name %||% "")) %in% c("Origin", "Destination"))
  }
  if ("length_m" %in% names(route_sf)) {
    lengths_m <- suppressWarnings(as.numeric(route_sf$length_m %||% 0))
    lengths_m[!is.finite(lengths_m)] <- 0
    keep <- keep & lengths_m > 1
  }
  out <- route_sf[keep, , drop = FALSE]
  if (nrow(out) > 1 && all(c("road_id", "segment_index") %in% names(out))) {
    edge_key <- paste(out$road_id, out$segment_index, sep = "::")
    out <- out[c(TRUE, edge_key[-1] != edge_key[-length(edge_key)]), , drop = FALSE]
  }
  if (nrow(out) == 0) route_sf[0, , drop = FALSE] else out
}

# Why: the snapped routing graph occasionally deviates from the live road
# polylines by tens of meters around messy junctions; if those drifted
# segments are kept the rendered route line peels away from the road below
# it on the basemap.
# What: returns the filtered route_sf with each segment kept only when its
# midpoint is within snap_buffer_m of the live roads_sf polyline; falls back
# to the unfiltered rsf when roads_sf is unavailable or no segment matches.
# How: samples each segment's midpoint in EPSG:5070, finds its nearest
# feature in roads_sf, computes the straight-line distance, and keeps
# segments whose distance is <= max(60, snap_buffer_m).
# When: invoked from build_route_display_sf when a live roads layer is
# available, just before stitching the final display geometry.
# Impact: snap_buffer_m is the user-visible tolerance — too tight and you
# clip valid segments at OSM/Census mismatches; too loose and the route
# line visibly drifts off-road in cluttered downtowns.
route_display_sf_from_live_roads <- function(route_sf, roads_sf = NULL, snap_buffer_m = 75) {
  rsf <- filter_display_route_sf(route_sf)
  if (is.null(rsf) || nrow(rsf) == 0) return(rsf)
  if ("segment_index" %in% names(rsf)) {
    seg_idx <- suppressWarnings(as.numeric(rsf$segment_index %||% seq_len(nrow(rsf))))
    seg_idx[!is.finite(seg_idx)] <- seq_len(nrow(rsf))[!is.finite(seg_idx)]
    rsf <- rsf[order(seg_idx), , drop = FALSE]
  } else if ("edge_id" %in% names(rsf)) {
    edge_idx <- suppressWarnings(as.numeric(rsf$edge_id %||% seq_len(nrow(rsf))))
    edge_idx[!is.finite(edge_idx)] <- seq_len(nrow(rsf))[!is.finite(edge_idx)]
    rsf <- rsf[order(edge_idx), , drop = FALSE]
  }
  if (nrow(rsf) > 1) {
    geom_key <- tryCatch(sf::st_as_text(sf::st_geometry(rsf)), error = function(e) rep("", nrow(rsf)))
    rsf <- rsf[c(TRUE, geom_key[-1] != geom_key[-length(geom_key)]), , drop = FALSE]
  }
  if (!is.null(roads_sf) && inherits(roads_sf, "sf") && nrow(roads_sf) > 0 && nrow(rsf) > 1) {
    rsf <- tryCatch(
      {
        route_bbox <- sf::st_as_sfc(sf::st_bbox(rsf))
        candidate_roads <- tryCatch(
          roads_sf[suppressWarnings(lengths(sf::st_intersects(roads_sf, route_bbox))) > 0, , drop = FALSE],
          error = function(e) roads_sf
        )
        if (nrow(candidate_roads) == 0) return(rsf)
        rsf_proj <- suppressWarnings(sf::st_transform(rsf, 5070))
        roads_proj <- suppressWarnings(sf::st_transform(candidate_roads, 5070))
        sample_points <- suppressWarnings(sf::st_line_sample(sf::st_geometry(rsf_proj), sample = 0.5))
        sample_points <- tryCatch(suppressWarnings(sf::st_cast(sample_points, "POINT", warn = FALSE)), error = function(e) NULL)
        if (is.null(sample_points) || length(sample_points) != nrow(rsf_proj)) return(rsf)
        point_sf <- sf::st_sf(seg_idx = seq_len(nrow(rsf_proj)), geometry = sample_points, crs = 5070)
        nearest_idx <- suppressWarnings(sf::st_nearest_feature(point_sf, roads_proj))
        nearest_idx[!is.finite(nearest_idx)] <- NA_integer_
        has_match <- is.finite(nearest_idx) & nearest_idx >= 1L & nearest_idx <= nrow(roads_proj)
        if (!any(has_match)) return(rsf)
        keep_mask <- rep(TRUE, nrow(rsf_proj))
        distances_m <- rep(Inf, nrow(rsf_proj))
        distances_m[has_match] <- suppressWarnings(as.numeric(sf::st_distance(
          point_sf[has_match, , drop = FALSE],
          roads_proj[nearest_idx[has_match], , drop = FALSE],
          by_element = TRUE
        )))
        keep_mask[has_match] <- is.finite(distances_m[has_match]) & distances_m[has_match] <= max(60, snap_buffer_m)
        if (any(keep_mask) && !all(keep_mask)) rsf[keep_mask, , drop = FALSE] else rsf
      },
      error = function(e) rsf
    )
  }
  rsf
}

# Why: per-edge LINESTRINGs in the OSM source data don't always share the
# exact same endpoint coordinates with their neighbours - two ways meeting
# at the same intersection can have endpoints up to ROUTE_NODE_SNAP_METERS
# (25 m) apart. Concatenating them via st_combine yields a MULTILINESTRING
# with visible junction gaps at high zoom.
# What: returns a single continuous LINESTRING (sfc) for the path, with each
# consecutive edge oriented head-to-tail and tiny endpoint mismatches
# bridged by aligning the next edge's first point to the previous edge's
# last point.
# How: walks the rsf rows in order, infers each edge's orientation from the
# nearest endpoint to the running tail, drops duplicated joining vertices,
# and assembles one rbind'd coordinate matrix.
# When: invoked from build_route_display_sf when no geometry_override is
# supplied; runs once per route per query (~ms even for 500-edge routes).
# Impact: removes all visible junction gaps in the rendered route. Falls
# back to st_combine on any error so a malformed edge never fails the build.
stitch_route_geometry <- function(rsf) {
  if (is.null(rsf) || nrow(rsf) == 0) return(NULL)
  geom <- sf::st_geometry(rsf)
  coords_all <- suppressWarnings(sf::st_coordinates(geom))
  if (is.null(coords_all) || nrow(coords_all) == 0) return(NULL)
  L1 <- if ("L1" %in% colnames(coords_all)) as.integer(coords_all[, "L1"]) else rep(1L, nrow(coords_all))
  n <- nrow(rsf)
  per_edge <- split(coords_all[, c("X", "Y"), drop = FALSE], L1)
  per_edge <- per_edge[as.character(seq_len(n))]
  per_edge <- lapply(per_edge, function(m) matrix(m, ncol = 2L, byrow = FALSE))
  if (n == 1L) {
    return(sf::st_sfc(sf::st_linestring(per_edge[[1]]), crs = sf::st_crs(rsf)))
  }
  # Orient first edge: choose the end closer to the second edge's nearest end
  cur <- per_edge[[1]]; nxt <- per_edge[[2]]
  d_end_to_nxt   <- min(sqrt(rowSums((nxt - matrix(cur[nrow(cur), ], nrow(nxt), 2, byrow = TRUE))^2)))
  d_start_to_nxt <- min(sqrt(rowSums((nxt - matrix(cur[1, ], nrow(nxt), 2, byrow = TRUE))^2)))
  if (d_start_to_nxt < d_end_to_nxt) cur <- cur[rev(seq_len(nrow(cur))), , drop = FALSE]
  oriented <- vector("list", n)
  oriented[[1]] <- cur
  for (i in seq.int(2L, n)) {
    prev_tail <- oriented[[i - 1L]][nrow(oriented[[i - 1L]]), ]
    cur <- per_edge[[i]]
    d_start <- sqrt(sum((prev_tail - cur[1, ])^2))
    d_end   <- sqrt(sum((prev_tail - cur[nrow(cur), ])^2))
    if (d_end < d_start) cur <- cur[rev(seq_len(nrow(cur))), , drop = FALSE]
    # Snap first point to prev_tail to bridge sub-snap-radius gaps; this
    # collapses up to ~25 m of mismatch without distorting visible shape.
    cur[1, ] <- prev_tail
    # Drop the duplicate joining vertex
    if (nrow(cur) > 1L) cur <- cur[-1L, , drop = FALSE]
    oriented[[i]] <- cur
  }
  combined <- do.call(rbind, oriented)
  sf::st_sfc(sf::st_linestring(combined), crs = sf::st_crs(rsf))
}

# Why: Leaflet renders a single LINESTRING faster than per-edge polylines and
# avoids visible junction gaps; we collapse a multi-edge route_sf into one
# row with a stitched geometry for display.
# What: returns a single-row sf (length_m summed, edge_id/segment_index = 1,
# route_connector = FALSE) whose geometry is either the supplied
# geometry_override or the stitched output of stitch_route_geometry.
# How: filters connectors, runs stitch_route_geometry inside tryCatch, and
# falls back to st_combine on any error so the build never aborts.
# When: called from native_plan_routes after the path is assembled, once
# per route alternative; the resulting display_sf is what server.R hands to
# leaflet::addPolylines.
# Impact: stitching is the difference between a clean unbroken route line
# and the per-edge MULTILINESTRING with gaps at every junction.
build_route_display_sf <- function(route_sf, geometry_override = NULL) {
  rsf <- filter_display_route_sf(route_sf)
  if (is.null(rsf) || nrow(rsf) == 0) return(rsf)
  geom <- geometry_override
  if (is.null(geom)) {
    geom <- tryCatch(
      stitch_route_geometry(rsf),
      error = function(e) NULL
    )
    if (is.null(geom)) {
      geom <- tryCatch(
        sf::st_sfc(sf::st_combine(sf::st_geometry(rsf)), crs = sf::st_crs(rsf)),
        error = function(e) sf::st_geometry(rsf[1, , drop = FALSE])
      )
    }
  }
  out <- rsf[1, , drop = FALSE]
  sf::st_geometry(out) <- geom
  out$edge_id <- 1L
  out$segment_index <- 1L
  out$length_m <- sum(suppressWarnings(as.numeric(rsf$length_m %||% 0)), na.rm = TRUE)
  out$route_connector <- FALSE
  out
}

# Why: routing pipeline needs this small primitive in a hot loop; isolating
# it keeps the planner readable.
# What: Returns route_obj's pre-built display_sf when present, else lazily
# computes one via route_display_sf_from_live_roads — the lazy path is what
# server.R uses when the route was built without a live roads overlay.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
route_display_sf <- function(route_obj = NULL, roads_sf = NULL) {
  if (is.null(route_obj)) return(NULL)
  display_sf <- route_obj$display_sf %||% NULL
  if (!is.null(display_sf) && inherits(display_sf, "sf") && nrow(display_sf) > 0) return(display_sf)
  route_display_sf_from_live_roads(route_obj$route_sf %||% NULL, roads_sf = roads_sf)
}

# Why: the route summary panel and tie-breaker (route_exposure_index) need
# per-band mileage totals so the user can see how much of the trip is in
# transparent / green / yellow / red and so the planner can rank routes
# whose total mileage is similar.
# What: returns a list with total_miles plus *_miles fields per risk band,
# a red_weighted_miles term that emphasises the worst red segments, and a
# nontransparent_miles total used for ranking.
# How: converts length_m to miles, clamps segment_risk to [0, 1], then sums
# miles inside each band threshold (RISK_GREEN_MIN / RISK_YELLOW_MIN /
# RISK_RED_MIN); red_weighted_miles multiplies by (risk - RISK_RED_MIN).
# When: called once per built route in native_plan_routes when assembling
# the route summary, and again in route_exposure_index when ranking.
# Impact: changing the band thresholds here without updating the rest of
# the scoring stack would make the route summary disagree with the polygon
# colours on the same map.
route_exposure_summary <- function(route_sf) {
  if (is.null(route_sf) || nrow(route_sf) == 0) {
    return(list(
      total_miles = 0,
      transparent_miles = 0,
      green_miles = 0,
      yellow_miles = 0,
      red_miles = 0,
      red_weighted_miles = 0,
      nontransparent_miles = 0
    ))
  }
  miles <- pmax(0, suppressWarnings(as.numeric(route_sf$length_m))) / 1609.344
  risk <- pmax(0, pmin(1, suppressWarnings(as.numeric(route_sf$segment_risk))))
  risk[!is.finite(risk)] <- 0
  # Compute each band mask once (SOP: no redundant work). Previously
  # `risk > RISK_RED_MIN` was evaluated 3x and `risk >= RISK_GREEN_MIN` 2x
  # per call. Byte-identical to the prior form (5000/5000 incl. boundary /
  # NA / Inf / empty; see scratchpad exposure_equiv harness, cycle 18).
  at_green    <- risk >= RISK_GREEN_MIN
  red         <- risk > RISK_RED_MIN
  red_miles_v <- miles[red]
  list(
    total_miles = sum(miles, na.rm = TRUE),
    transparent_miles = sum(miles[risk < RISK_GREEN_MIN], na.rm = TRUE),
    green_miles = sum(miles[at_green & risk < RISK_YELLOW_MIN], na.rm = TRUE),
    yellow_miles = sum(miles[risk >= RISK_YELLOW_MIN & risk <= RISK_RED_MIN], na.rm = TRUE),
    red_miles = sum(red_miles_v, na.rm = TRUE),
    red_weighted_miles = sum(red_miles_v * pmax(risk[red] - RISK_RED_MIN, 0.01), na.rm = TRUE),
    nontransparent_miles = sum(miles[at_green], na.rm = TRUE)
  )
}

# Why: the route popup shows an "X.X mi on highway" badge and the safest /
# metro profiles use highway_share as a tie-breaker, so we need to know how
# much of the route runs on Interstate / US / State tier road and how much
# is local-road approach mileage at either end.
# What: returns a list(highway_miles, highway_share, pre_highway_miles,
# post_highway_miles, interior_local_miles); shares 0 when no highway tier
# is touched.
# How: builds a logical mask of high-priority-tier segments via
# route_high_priority_tier, then bookends the highway run by the first/last
# index of TRUE; pre/post are sums outside that range, interior_local is
# sum of FALSE inside it.
# When: called once per built route when assembling the route summary.
# Impact: changing route_high_priority_tier (or the route_tier strings it
# matches) silently changes what counts as "highway" in this summary.
route_highway_summary <- function(route_sf) {
  if (is.null(route_sf) || nrow(route_sf) == 0) {
    return(list(
      highway_miles = 0,
      highway_share = 0,
      pre_highway_miles = 0,
      post_highway_miles = 0,
      interior_local_miles = 0
    ))
  }
  miles <- pmax(0, suppressWarnings(as.numeric(route_sf$length_m))) / 1609.344
  miles[!is.finite(miles)] <- 0
  high_mask <- route_high_priority_tier(route_sf$route_tier %||% rep("", nrow(route_sf)))
  total_miles <- sum(miles, na.rm = TRUE)
  highway_miles <- sum(miles[high_mask], na.rm = TRUE)
  if (!any(high_mask, na.rm = TRUE)) {
    return(list(
      highway_miles = highway_miles,
      highway_share = if (total_miles > 0) highway_miles / total_miles else 0,
      pre_highway_miles = total_miles,
      post_highway_miles = 0,
      interior_local_miles = 0
    ))
  }
  first_idx <- which(high_mask)[1]
  last_idx <- utils::tail(which(high_mask), 1)
  pre_highway_miles <- if (first_idx > 1) sum(miles[seq_len(first_idx - 1L)], na.rm = TRUE) else 0
  post_highway_miles <- if (last_idx < length(miles)) sum(miles[(last_idx + 1L):length(miles)], na.rm = TRUE) else 0
  interior_idx <- seq.int(first_idx, last_idx)
  interior_local_miles <- sum(miles[interior_idx][!high_mask[interior_idx]], na.rm = TRUE)
  list(
    highway_miles = highway_miles,
    highway_share = if (total_miles > 0) highway_miles / total_miles else 0,
    pre_highway_miles = pre_highway_miles,
    post_highway_miles = post_highway_miles,
    interior_local_miles = interior_local_miles
  )
}


# Why: when a query point (origin or destination) is more than 100 m from
# the nearest routable graph node, the rendered route line would look like
# it starts mid-road; we draw a "connector" stub from the query point to
# the entry node so the line visibly reaches the user's location.
# What: returns a single-row sf with the connector geometry (LINESTRING in
# CRS 4326), styled to match the parent route, or NULL when the gap is
# under 100 m or the inputs are degenerate.
# How: builds a 2-point linestring from point to node_row's lon/lat, length
# in EPSG:5070 meters; populates the standard route_sf columns with
# connector-specific defaults (zero risk, "connector" cause kind, road_class
# "Connector" so filter_display_route_sf can drop it from the on-map line).
# When: called by native_plan_routes after each route is assembled, twice
# per route (origin connector + destination connector).
# Impact: the route_connector / road_class flags are what filter_display_
# route_sf reads to hide connectors from the rendered line; mis-flagging
# leaves a visible stub on the map.
make_route_connector_sf <- function(point, node_row, route_name, route_rank, route_color, route_weight, route_opacity, connector_name) {
  if (is.null(node_row) || nrow(node_row) == 0) return(NULL)
  mat <- rbind(c(point$lon, point$lat), c(node_row$lon[1], node_row$lat[1]))
  if (any(!is.finite(mat))) return(NULL)
  connector_geom <- sf::st_sfc(sf::st_linestring(mat), crs = 4326)
  connector_len <- suppressWarnings(as.numeric(sf::st_length(sf::st_transform(connector_geom, 5070))))
  if (!is.finite(connector_len)) connector_len <- 0
  if (connector_len < 100) return(NULL)
  sf::st_sf(
    edge_id = NA_integer_,
    segment_index = NA_integer_,
    road_id = sprintf("connector-%s-%s", route_rank, tolower(gsub("[^a-z0-9]+", "-", connector_name))),
    road_name = connector_name,
    road_class = "Connector",
    from_node = NA_character_,
    to_node = NA_character_,
    from_x = NA_real_,
    from_y = NA_real_,
    to_x = NA_real_,
    to_y = NA_real_,
    length_m = connector_len,
    edge_weight = connector_len,
    segment_risk = 0,
    closure_penalty = 0,
    reason_text = sprintf("%s connector to the nearest primary road network.", connector_name),
    official_reason_text = "",
    official_source = "",
    official_cause_kind = "connector",
    route_rank = route_rank,
    route_name = route_name,
    route_color = route_color,
    route_weight = route_weight,
    route_opacity = route_opacity,
    route_connector = TRUE,
    geometry = connector_geom
  )
}


# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Joins two route-summary notes (base_note and extra_note) with a
# single space, dropping NULL/empty inputs and returning NULL only when
# both are empty.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
append_route_mode_note <- function(base_note = NULL, extra_note = NULL) {
  base_note <- trimws(as.character(base_note %||% ""))
  extra_note <- trimws(as.character(extra_note %||% ""))
  if (!nzchar(base_note) && !nzchar(extra_note)) return(NULL)
  if (!nzchar(base_note)) return(extra_note)
  if (!nzchar(extra_note)) return(base_note)
  paste(base_note, extra_note)
}

# Why: when the planner cannot find a distinct route for one of the three
# profiles (because the corridor only admits one viable path), we clone the
# best available route under the missing profile's identity so the UI still
# renders three labelled choices rather than collapsing to one.
# What: returns a deep-ish copy of route_obj with route_rank / route_name /
# route_color / route_weight / route_opacity rewritten to match profile, and
# a "fallback used" flag set on the summary.
# How: copies the input, overwrites the styling/identity fields on route_sf,
# display_sf, and summary, sets summary$route_reused_fallback = TRUE, and
# appends note to summary$summary_reason via append_route_mode_note.
# When: called from native_plan_routes when a profile's A* search returns no
# distinct path and we need to fill the slot with a labelled clone.
# Impact: the summary_reason copy is what tells the user "this is the same
# as Fastest because the corridor has no separate Safest path"; if note is
# omitted, that distinction disappears.
clone_route_profile <- function(route_obj, profile, note = NULL) {
  if (is.null(route_obj)) return(NULL)
  out <- route_obj
  if (!is.null(out$route_sf) && nrow(out$route_sf) > 0) {
    out$route_sf$route_rank <- profile$route_rank
    out$route_sf$route_name <- profile$route_name
    out$route_sf$route_color <- profile$route_color
    out$route_sf$route_weight <- profile$route_weight
    out$route_sf$route_opacity <- profile$route_opacity
  }
  if (!is.null(out$display_sf) && inherits(out$display_sf, "sf") && nrow(out$display_sf) > 0) {
    out$display_sf$route_rank <- profile$route_rank
    out$display_sf$route_name <- profile$route_name
    out$display_sf$route_color <- profile$route_color
    out$display_sf$route_weight <- profile$route_weight
    out$display_sf$route_opacity <- profile$route_opacity
  }
  out$summary$route_rank <- profile$route_rank
  out$summary$route_name <- profile$route_name
  out$key <- profile$key %||% tolower(profile$route_name %||% "route")
  base_reason <- out$summary$summary_reason %||% "Closest available corridor used."
  out$summary$summary_reason <- append_route_mode_note(base_reason, note)
  out$summary$route_reused_fallback <- TRUE
  out
}



# Why: when ranking route alternatives for the safest profile, raw avg_risk
# under-penalises short red stretches; we need a single scalar that scores
# red exposure heavily and degrades gracefully as more of the route slips
# into yellow/green.
# What: returns a non-negative numeric exposure score; higher means worse.
# Always finite, never negative.
# How: weighted sum of red_miles (5000), red_weighted_miles (7000),
# yellow_miles (220), green_miles (24), nontransparent_miles (3), and
# avg_risk (180); each input is coerced to a finite numeric first.
# When: invoked by native_plan_routes when comparing route candidates within
# the safest-profile tier and as a tie-breaker between profiles.
# Impact: the per-band coefficients are the lever for "how much worse is a
# red mile vs a yellow mile" — adjust them to retune the safest profile's
# willingness to detour.
route_exposure_index <- function(route_obj = NULL) {
  sm <- route_obj$summary %||% list()
  red <- suppressWarnings(as.numeric(sm$red_miles %||% 0))
  red_weighted <- suppressWarnings(as.numeric(sm$red_weighted_miles %||% 0))
  yellow <- suppressWarnings(as.numeric(sm$yellow_miles %||% 0))
  green <- suppressWarnings(as.numeric(sm$green_miles %||% 0))
  nontrans <- suppressWarnings(as.numeric(sm$nontransparent_miles %||% 0))
  avg <- suppressWarnings(as.numeric(sm$avg_risk %||% 0))
  red[!is.finite(red)] <- 0
  red_weighted[!is.finite(red_weighted)] <- 0
  yellow[!is.finite(yellow)] <- 0
  green[!is.finite(green)] <- 0
  nontrans[!is.finite(nontrans)] <- 0
  avg[!is.finite(avg)] <- 0
  (red * 5000) + (red_weighted * 7000) + (yellow * 220) + (green * 24) + (nontrans * 3) + (avg * 180)
}


# Why: this is the public entry point used by the Shiny server when the user
# requests a route plan; everything else in the routing pipeline is plumbed
# through here so callers do not need to know about graphs, profiles, or A*.
# What: takes a start/end search string (city, county, ZIP), the live risk
# polygons, and an optional pre-built segment table; returns a list with the
# resolved start/end points, three route objects (fastest, safest, metro), and
# a status message.
# How: resolves the query strings to spatial points, builds (or reuses) the
# routable segment table, then delegates to native_plan_routes which runs the
# three profile-specific A* searches and packages each result.
# When: invoked from server.R whenever the user clicks "Plan route"; runs once
# per user request, no shared state.
# Impact: the only function the UI layer sees - any change to its return shape
# affects every downstream consumer in the Shiny app.
plan_route_options <- function(start_query, end_query, zips, horizon_key = "live", route_segments = NULL, progress = NULL) {
  notify_progress(progress, 0.20, "Resolving Wisconsin origin and destination.")
  start_point <- resolve_search_point(start_query)
  end_point <- resolve_search_point(end_query)
  if (is.null(start_point) || is.null(end_point)) {
    notify_progress(progress, 0.22, "Route origin or destination could not be resolved.")
    return(list(message = "Route start or destination could not be resolved in Wisconsin.", routes = list(), start_point = start_point, end_point = end_point))
  }
  notify_progress(progress, 0.30, "Loading the live Wisconsin road-risk graph.")
  full_segments <- route_segments
  if (is.null(full_segments) || nrow(full_segments) == 0) {
    full_segments <- build_route_segments(zips, horizon_key)
  }
  if (is.null(full_segments) || nrow(full_segments) == 0) {
    return(list(message = "No routable Wisconsin road segments were available for this request.",
                routes = list(), start_point = start_point, end_point = end_point))
  }
  return(native_plan_routes(start_point, end_point, full_segments,
                            progress = progress, horizon_key = horizon_key))
}

# Why: the route summary card in the Shiny UI must render the right thing in
# four distinct states (no request yet, request failed, single route, multi-
# route choice) and the rendering branches don't fit cleanly into a renderUI
# expression in server.R.
# What: returns a Shiny tagList holding a radio-button group of route choices
# plus copy text, or a single-line "empty" / "error" message div.
# How: branches first on missing/empty route_result, then on a non-empty
# message field with no routes, otherwise builds choice labels of the form
# "<name> | <miles> | <duration> | <label>" and emits radioButtons.
# When: invoked from output$route_summary in server.R whenever route_result
# is invalidated (after each plan_route_options call).
# Impact: the radio button input ID "route_choice" is the contract with
# server.R's selected-rank handler — renaming it without updating the
# observer breaks route selection.
render_route_summary_ui <- function(route_result) {
  if (is.null(route_result) || (!nzchar(route_result$message %||% "") && length(route_result$routes) == 0)) {
    return(shiny::div(class = "route-summary-empty", "Enter a Wisconsin start and destination to compute a risk-aware route."))
  }
  if (nzchar(route_result$message %||% "") && length(route_result$routes) == 0) {
    return(shiny::div(class = "route-summary-empty", escape_html(route_result$message)))
  }
  route_choices <- stats::setNames(
    vapply(route_result$routes, function(rt) as.character(rt$summary$route_rank %||% 1L), character(1)),
    vapply(
      route_result$routes,
      function(rt) {
        sm <- rt$summary
        sprintf(
          "%s | %.1f mi | %s | %s",
          sm$route_name %||% "Route",
          sm$total_miles %||% 0,
          format_duration_minutes(sm$duration_minutes %||% NA_real_),
          sm$label %||% "Transparent"
        )
      },
      character(1)
    )
  )
  shiny::tagList(
    shiny::div(
      class = "route-choice-group",
      shiny::radioButtons(
        "route_choice",
        label = NULL,
        choices = route_choices,
        selected = unname(route_choices[[1]]),
        inline = FALSE
      )
    ),
    shiny::div(
      class = "route-summary-copy",
      "Choose an option to compare shortest-time, safest, and city-corridor routing behavior."
    )
  )
}

# Why: the route-details panel needs a small ordered list of human directions
# (e.g. "Take I-94 W") rather than the raw per-edge sequence; routes can have
# hundreds of edges so we have to compress consecutive same-road runs and
# fold the middle stretch into a single placeholder when there are too many.
# What: returns a data.frame(step, instruction, miles); empty when no
# instructions are derivable.
# How: prefers route_obj$route_sf$step_instruction when populated; otherwise
# groups consecutive rows by road_name and emits "Continue on <road>" per
# group, then trims to keep_front + 1 placeholder + keep_back rows when the
# count exceeds max_steps.
# When: called by render_route_details_ui to populate the directions list.
# Impact: changing the keep_front/keep_back constants reshapes how long
# routes appear; the placeholder "Continue through N intermediate ..." line
# is the user-facing signal that some steps were folded.
route_direction_steps <- function(route_obj, max_steps = 10L) {
  if (is.null(route_obj) || is.null(route_obj$route_sf) || nrow(route_obj$route_sf) == 0) {
    return(data.frame(step = integer(), instruction = character(), miles = numeric(), stringsAsFactors = FALSE))
  }
  rsf <- filter_display_route_sf(route_obj$route_sf)
  if (nrow(rsf) == 0) {
    return(data.frame(step = integer(), instruction = character(), miles = numeric(), stringsAsFactors = FALSE))
  }
  if ("step_instruction" %in% names(rsf) && any(nzchar(trimws(as.character(rsf$step_instruction %||% ""))))) {
    miles <- pmax(0, suppressWarnings(as.numeric(rsf$length_m))) / 1609.344
    steps <- data.frame(
      instruction = as.character(rsf$step_instruction %||% ""),
      miles = miles,
      stringsAsFactors = FALSE
    )
    steps <- steps[nzchar(trimws(steps$instruction)), , drop = FALSE]
    if (nrow(steps) == 0) {
      return(data.frame(step = integer(), instruction = character(), miles = numeric(), stringsAsFactors = FALSE))
    }
    if (nrow(steps) > max_steps) {
      keep_front <- 4L
      keep_back <- 3L
      middle_idx <- seq.int(keep_front + 1L, nrow(steps) - keep_back)
      middle_miles <- sum(steps$miles[middle_idx], na.rm = TRUE)
      steps <- flows_bind_rows(
        steps[seq_len(keep_front), , drop = FALSE],
        data.frame(instruction = sprintf("Continue through %d intermediate navigation steps.", length(middle_idx)), miles = middle_miles, stringsAsFactors = FALSE),
        steps[(nrow(steps) - keep_back + 1L):nrow(steps), , drop = FALSE]
      )
    }
    steps$step <- seq_len(nrow(steps))
    return(steps)
  }
  road_name <- trimws(as.character(rsf$road_name %||% "Wisconsin road"))
  road_name[!nzchar(road_name)] <- "Wisconsin road"
  is_connector <- rep(FALSE, nrow(rsf))
  miles <- pmax(0, suppressWarnings(as.numeric(rsf$length_m))) / 1609.344
  group_break <- c(TRUE, road_name[-1] != road_name[-length(road_name)] | is_connector[-1] != is_connector[-length(is_connector)])
  group_id <- cumsum(group_break)
  grouped <- lapply(split(seq_len(nrow(rsf)), group_id), function(idx) {
    nm <- road_name[idx[1]]
    connector_flag <- is_connector[idx[1]]
    seg_miles <- sum(miles[idx], na.rm = TRUE)
    instruction <- if (connector_flag && grepl("origin", nm, ignore.case = TRUE)) {
      "Leave the origin and connect to the nearest road corridor."
    } else if (connector_flag && grepl("destination", nm, ignore.case = TRUE)) {
      "Leave the main corridor and continue to the destination."
    } else if (connector_flag) {
      paste("Use", nm)
    } else {
      paste("Continue on", nm)
    }
    data.frame(instruction = instruction, miles = seg_miles, stringsAsFactors = FALSE)
  })
  steps <- flows_bind_rows(grouped)
  if (nrow(steps) == 0) {
    return(data.frame(step = integer(), instruction = character(), miles = numeric(), stringsAsFactors = FALSE))
  }
  if (nrow(steps) > max_steps) {
    keep_front <- 4L
    keep_back <- 3L
    middle_idx <- seq.int(keep_front + 1L, nrow(steps) - keep_back)
    middle_miles <- sum(steps$miles[middle_idx], na.rm = TRUE)
    steps <- flows_bind_rows(
      steps[seq_len(keep_front), , drop = FALSE],
      data.frame(instruction = sprintf("Continue through %d intermediate road changes.", length(middle_idx)), miles = middle_miles, stringsAsFactors = FALSE),
      steps[(nrow(steps) - keep_back + 1L):nrow(steps), , drop = FALSE]
    )
  }
  steps$step <- seq_len(nrow(steps))
  steps
}

# Why: when the user picks one of the routes from the summary panel, the
# details panel below has to display the matching route's distance / ETA /
# avg-and-peak risk, the canonical behavior description, and a step list —
# composing all of that in server.R inline would be hard to read.
# What: returns a single Shiny div (or NULL when there are no routes) with
# the title, meta line, behavior description, summary reason, optional
# official-sources line, and an ordered step list.
# How: looks up the matching route by selected_rank (defaults to the first
# route), pulls the summary, computes step rows via route_direction_steps,
# and emits the panel with HTML-escaped text.
# When: invoked from output$route_details whenever route_result or
# input$route_choice changes.
# Impact: the CSS class names used here ("route-details-panel" /
# "route-step-list" / etc.) are the integration surface with styles.css —
# renaming any of them without a paired CSS edit unstyles the panel.
render_route_details_ui <- function(route_result, selected_rank = NA_real_) {
  if (is.null(route_result) || length(route_result$routes %||% list()) == 0) return(NULL)
  if (!is.finite(selected_rank)) {
    selected_rank <- suppressWarnings(as.numeric(route_result$routes[[1]]$summary$route_rank %||% 1L))
  }
  route_idx <- which(vapply(route_result$routes, function(rt) identical(suppressWarnings(as.numeric(rt$summary$route_rank %||% NA_real_)), selected_rank), logical(1)))
  if (length(route_idx) == 0) route_idx <- 1L
  route_obj <- route_result$routes[[route_idx[1]]]
  sm <- route_obj$summary
  steps <- route_direction_steps(route_obj)
  route_key <- tolower(as.character(route_obj$key %||% gsub("[^a-z]+", "", sm$route_name %||% "")))
  shiny::div(
    class = "route-details-panel",
    shiny::div(class = "route-details-title", escape_html(sm$route_name %||% "Selected route")),
    shiny::div(
      class = "route-details-meta",
      sprintf(
        "Distance %.1f mi • ETA %s • Avg %s • Peak %s",
        sm$total_miles %||% 0,
        format_duration_minutes(sm$duration_minutes %||% NA_real_),
        sm$label %||% "Transparent",
        risk_label_from_score(sm$peak_risk %||% 0)
      )
    ),
    shiny::div(class = "route-summary-copy", escape_html(route_behavior_description(route_key))),
    shiny::div(class = "route-summary-copy", escape_html(sm$summary_reason %||% "All clear.")),
    if (nzchar(trimws(as.character(sm$official_source_summary %||% "")))) shiny::div(class = "route-summary-copy", escape_html(paste0("Official sources: ", sm$official_source_summary))),
    if (nrow(steps) == 0) {
      shiny::div(class = "route-summary-copy", "Detailed directions are not available for this route yet.")
    } else {
      shiny::tags$ol(
        class = "route-step-list",
        lapply(seq_len(nrow(steps)), function(i) {
          shiny::tags$li(
            class = "route-step-item",
            shiny::span(class = "route-step-instruction", escape_html(steps$instruction[i] %||% "")),
            shiny::span(class = "route-step-miles", sprintf("%.1f mi", steps$miles[i] %||% 0))
          )
        })
      )
    }
  )
}
