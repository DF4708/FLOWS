# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/zone_alerts.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: SAME codes from CAP alerts encode counties as either 5 or 6 digits;
# we want a clean 5-digit county GEOID restricted to TARGET_STATE_FIPS.
# What: returns a 5-character GEOID, or NA_character_ when the code is
# malformed or out of state.
# How: strips non-digits, trims to the trailing 5 digits, and verifies the
# state prefix matches TARGET_STATE_FIPS.
# When: invoked by extract_alert_county_geoids while shaping each alert.
# Impact: an over-aggressive substring would silently misclassify alerts;
# the state-prefix check guards against accidentally bringing in adjacent
# states.
normalize_same_to_county_geoid <- function(code) {
  digits <- gsub("[^0-9]", "", safe_string(code))
  if (!nzchar(digits)) return(NA_character_)
  if (nchar(digits) == 6) digits <- substr(digits, 2, 6)
  if (nchar(digits) > 5) digits <- substr(digits, nchar(digits) - 4, nchar(digits))
  if (nchar(digits) != 5) return(NA_character_)
  if (substr(digits, 1, 2) != TARGET_STATE_FIPS) return(NA_character_)
  digits
}

# Why: NWS alerts carry geography in three forms (UGC, SAME, areaDesc); we
# fuse all three into a clean list of WI county GEOIDs.
# What: returns a unique character vector of 5-digit county GEOIDs that
# exist in the local county lookup.
# How: parses SAME -> normalize_same_to_county_geoid, parses WIC* UGCs ->
# state+suffix, parses WIZ* zone UGCs through the learned zone-county map,
# and last-resort matches county names within areaDesc text.
# When: called per alert by map_alert_record_to_zipcodes.
# Impact: an alert that escapes all three sources gets no ZIPs and goes
# unrendered on the map; the area_desc fallback is the last safety net.
extract_alert_county_geoids <- function(ugc_csv = "", same_csv = "", area_desc = "") {
  county_lookup <- get_county_zip_lookup()
  county_geoids <- character(0)

  same_codes <- split_pipe_codes(same_csv)
  if (length(same_codes) > 0) {
    same_geoids <- vapply(same_codes, normalize_same_to_county_geoid, character(1))
    county_geoids <- c(county_geoids, stats::na.omit(same_geoids))
  }

  ugc_codes <- toupper(split_pipe_codes(ugc_csv))
  if (length(ugc_codes) > 0) {
    county_ugc <- ugc_codes[grepl("^WIC[0-9]{3}$", ugc_codes)]
    if (length(county_ugc) > 0) {
      county_geoids <- c(county_geoids, paste0(TARGET_STATE_FIPS, substr(county_ugc, 4, 6)))
    }

    zone_ugc <- ugc_codes[grepl("^WIZ[0-9]{3}$", ugc_codes)]
    if (length(zone_ugc) > 0) {
      learned <- get_zone_county_lookup()
      learned_geoids <- unique(unlist(learned[zone_ugc], use.names = FALSE))
      county_geoids <- c(county_geoids, learned_geoids)
    }
  }

  area_text <- normalize_match_text(area_desc)
  if (nzchar(trimws(area_text))) {
    county_names <- unique(as.character(wi_counties$NAME))
    matched_names <- county_names[vapply(
      county_names,
      function(nm) {
        nm_norm <- normalize_match_text(nm)
        nzchar(nm_norm) && grepl(paste0("\\b", regex_escape(nm_norm), "\\b"), area_text, perl = TRUE)
      },
      logical(1)
    )]
    if (length(matched_names) > 0) {
      county_geoids <- c(county_geoids, unname(county_lookup$name_to_geoid[tolower(matched_names)]))
    }
  }

  county_geoids <- unique(as.character(stats::na.omit(county_geoids)))
  county_geoids[county_geoids %in% names(county_lookup$by_geoid)]
}

# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the unique zipcodes covered by any WIZ* zone UGC in the
# alert (using the cached zone -> zip lookup).
# How: regex match + sf geometry op + named vector build + guarded numeric
# coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_alert_zone_zipcodes <- function(ugc_csv = "") {
  ugc_codes <- toupper(split_pipe_codes(ugc_csv))
  zone_codes <- ugc_codes[grepl("^WIZ[0-9]{3}$", ugc_codes)]
  if (length(zone_codes) == 0) return(character(0))
  zone_lookup <- get_zone_zip_lookup()
  zone_hits <- unique(unlist(zone_lookup[zone_codes], use.names = FALSE))
  zone_hits <- unique(as.character(stats::na.omit(zone_hits)))
  zone_hits[nzchar(zone_hits)]
}

# Why: NWS forecast zones do not come with a static zone -> county map for
# Wisconsin, so we learn the mapping from the geometry of any alert that
# carries both a zone UGC and a polygon.
# What: invisibly returns NULL; updates the persisted zone -> county
# lookup with whatever counties intersect the alert geometry.
# How: extracts WIZ* codes from ugc_csv, intersects geometry_sfc with
# wi_counties, collects unique county GEOIDs, and calls
# update_zone_county_lookup.
# When: invoked per alert during fetch_wisconsin_alerts.
# Impact: this is how the zone vocabulary grows; missed alerts mean the
# next zone-only alert may map to no ZIPs.
learn_zone_counties_from_geometry <- function(ugc_csv = "", geometry_sfc = NULL) {
  zone_codes <- toupper(split_pipe_codes(ugc_csv))
  zone_codes <- zone_codes[grepl("^WIZ[0-9]{3}$", zone_codes)]
  if (length(zone_codes) == 0 || is.null(geometry_sfc) || length(geometry_sfc) == 0) return(invisible(NULL))
  if (isTRUE(all(sf::st_is_empty(geometry_sfc)))) return(invisible(NULL))
  county_hits <- suppressWarnings(sf::st_intersects(ensure_crs_4326(geometry_sfc), wi_counties))
  county_geoids <- unique(as.character(wi_counties$GEOID[unlist(county_hits, use.names = FALSE)]))
  county_geoids <- stats::na.omit(county_geoids)
  if (length(county_geoids) == 0) return(invisible(NULL))
  update_map <- setNames(rep(list(unique(county_geoids)), length(zone_codes)), zone_codes)
  update_zone_county_lookup(update_map)
  invisible(NULL)
}

# Why: produce the canonical list of ZIPs an alert covers, combining
# geometry-based hits, zone -> zip mapping, and county -> zip mapping.
# What: returns a unique character vector of zipcodes for the alert.
# How: spatial-join geometry_sfc with wi_zctas first, append zone-derived
# zips and county-derived zips, then unique-na-omit.
# When: called per alert in fetch_wisconsin_alerts to populate
# alert_zip_map.
# Impact: a missed source here causes the alert popup to be missing on
# affected ZIPs - the redundant lookups are intentional belts-and-braces.
map_alert_record_to_zipcodes <- function(alert_row, geometry_sfc = NULL) {
  zipcodes <- character(0)
  county_lookup <- get_county_zip_lookup()

  if (!is.null(geometry_sfc) && length(geometry_sfc) > 0 && !isTRUE(all(sf::st_is_empty(geometry_sfc)))) {
    hits <- suppressWarnings(sf::st_intersects(ensure_crs_4326(geometry_sfc), wi_zctas))
    zipcodes <- c(zipcodes, as.character(wi_zctas$zipcode[unique(unlist(hits, use.names = FALSE))]))
  }

  zone_zipcodes <- extract_alert_zone_zipcodes(alert_row$ugc_csv %||% "")
  if (length(zone_zipcodes) > 0) {
    zipcodes <- c(zipcodes, zone_zipcodes)
  }

  county_geoids <- extract_alert_county_geoids(alert_row$ugc_csv %||% "", alert_row$same_csv %||% "", alert_row$areaDesc %||% "")
  if (length(county_geoids) > 0) {
    zipcodes <- c(zipcodes, unlist(county_lookup$by_geoid[county_geoids], use.names = FALSE))
  }

  unique(as.character(stats::na.omit(zipcodes)))
}

# Why: apply_proximity_boost needs a per-zip neighbour graph; computing it
# from scratch is expensive (~all-pairs touches), so we cache aggressively.
# What: returns a list-of-integer-vectors where element i contains the
# indices of ZIPs that touch wi_zctas[i, ].
# How: project to EPSG:5070, run sf::st_touches, drop self, dedup.
# When: called once per process and cached in memory + on-disk; the
# snapshot has effectively infinite TTL because ZIP geometry rarely changes.
# Impact: the proximity-boost behaviour depends entirely on this graph;
# a stale snapshot for a redrawn ZCTA boundary would mis-link neighbours.
get_zip_neighbors <- function() {
  cached <- cache_get("derived", "zip_neighbors")
  if (!is.null(cached)) return(cached)
  persisted <- load_runtime_snapshot(ZIP_NEIGHBOR_SNAPSHOT_PATH, max_age_seconds = Inf)
  if (!is.null(persisted)) {
    cache_put("derived", "zip_neighbors", persisted, ttl_seconds = 24 * 3600)
    return(persisted)
  }

  projected_zips <- wi_zctas_proj
  neighbors <- suppressWarnings(sf::st_touches(projected_zips))
  neighbors <- lapply(
    seq_along(neighbors),
    function(i) {
      idx <- neighbors[[i]]
      idx <- idx[idx != i]
      unique(as.integer(idx))
    }
  )

  cache_put("derived", "zip_neighbors", neighbors, ttl_seconds = 24 * 3600)
  save_runtime_snapshot(ZIP_NEIGHBOR_SNAPSHOT_PATH, neighbors)
  neighbors
}
