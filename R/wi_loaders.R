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
  lookup
}

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

  dominant_zip <- vapply(
    road_ids,
    function(id) {
      z <- lookup[[id]] %||% character(0)
      if (length(z) == 0) return(NA_character_)
      vals <- zip_drive[z]
      if (length(vals) == 0 || all(!is.finite(vals))) return(NA_character_)
      z[which.max(ifelse(is.finite(vals), vals, -Inf))][1]
    },
    character(1)
  )

  driving_total_risk <- vapply(
    seq_along(road_ids),
    function(i) {
      id <- road_ids[i]
      z <- lookup[[id]] %||% character(0)
      vals <- zip_drive[z]
      vals <- vals[is.finite(vals)]
      if (length(vals) == 0) return(0)
      road_mult <- 0.85 + 0.15 * (roads$susceptibility[i] %||% 1)
      pmin(1, max(vals, na.rm = TRUE) * road_mult)
    },
    numeric(1)
  )

  is_blank_zip <- function(z) is.null(z) || length(z) == 0L || is.na(z) || !nzchar(as.character(z))
  safe_lookup <- function(tbl, key) {
    if (is_blank_zip(key)) return(NA_character_)
    val <- tbl[as.character(key)]
    if (is.na(val) || is.null(val)) return(NA_character_)
    as.character(val)
  }

  driving_reason_text <- vapply(
    road_ids,
    function(id) {
      z <- lookup[[id]] %||% character(0)
      vals <- zip_drive[z]
      if (length(z) == 0 || all(!is.finite(vals))) return("All clear.")
      best_zip <- z[which.max(ifelse(is.finite(vals), vals, -Inf))][1]
      reason <- safe_lookup(zip_reason, best_zip)
      if (!is.na(reason) && nzchar(reason)) return(reason)
      transport <- safe_lookup(zip_transport_reason, best_zip)
      if (!is.na(transport) && nzchar(transport)) return(transport)
      "All clear."
    },
    character(1)
  )

  road_source <- vapply(
    dominant_zip,
    function(best_zip) {
      if (is_blank_zip(best_zip)) return("Modeled ZIP risk")
      transport <- safe_lookup(zip_transport_reason, best_zip)
      if (!is.na(transport) && nzchar(trimws(transport))) {
        "Modeled ZIP risk + 511 ZIP transport signal"
      } else {
        "Modeled ZIP risk"
      }
    },
    character(1)
  )

  official_cause_text <- vapply(
    dominant_zip,
    function(best_zip) {
      if (is_blank_zip(best_zip)) return("none")
      transport <- safe_lookup(zip_transport_reason, best_zip)
      classify_official_transport_cause(if (is.na(transport)) "" else transport, "511 ZIP transport")
    },
    character(1)
  )

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

split_pipe_codes <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x) || !nzchar(trimws(x))) return(character(0))
  vals <- unlist(strsplit(as.character(x), "|", fixed = TRUE), use.names = FALSE)
  vals <- trimws(as.character(vals))
  unique(vals[nzchar(vals)])
}

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

get_zone_county_lookup <- function() {
  cached <- cache_get("derived", "zone_county_lookup")
  if (!is.null(cached)) return(cached)
  list()
}

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
