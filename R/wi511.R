# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/wi511.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Maps a 511WI winter road status string ("ice covered", "closed", "wet", etc.) to a fixed 0..1 risk score by keyword priority.
score_511_winter_status <- function(status) {
  s <- tolower(trimws(safe_string(status)))
  if (!nzchar(s)) return(0)
  if (grepl("closed|impassable|blocked|shutdown", s)) return(1.00)
  if (grepl("travel not advised|no travel|extremely hazardous|dangerous", s)) return(0.96)
  if (grepl("ice covered|glare ice|black ice", s)) return(0.92)
  if (grepl("partly ice|partially ice|patchy ice", s)) return(0.82)
  if (grepl("snow covered|hard packed snow", s)) return(0.76)
  if (grepl("slippery|icy|frost|packed snow", s)) return(0.62)
  if (grepl("wet|drifting snow|blowing snow", s)) return(0.40)
  if (grepl("normal|clear|good", s)) return(0.00)
  0.25
}

# Why: turn raw 511WI travel-time data (delay or current vs normal) into a
# normalised 0..1 risk score even when only some fields are present.
# What: returns a 0..1 score; 0 if no usable delay/normal data available.
# How: derives delay_minutes if missing (current - normal), then takes the
# pmax of an absolute-delay score (3/8/20 min thresholds) and a relative
# delay_ratio score (10%/30%/100%).
# When: invoked per 511WI travel-time record by fetch_511_travel_times_live.
# Impact: too-low thresholds light up minor congestion; the per-route
# baseline absorbs varying road lengths.
score_511_travel_delay <- function(delay_minutes = NA_real_, normal_minutes = NA_real_, current_minutes = NA_real_) {
  delay_minutes <- safe_numeric(delay_minutes)
  normal_minutes <- safe_numeric(normal_minutes)
  current_minutes <- safe_numeric(current_minutes)
  if (!is.finite(delay_minutes) && is.finite(current_minutes) && is.finite(normal_minutes)) {
    delay_minutes <- current_minutes - normal_minutes
  }
  if (!is.finite(delay_minutes) || delay_minutes <= 0) return(0)
  if (!is.finite(normal_minutes) || normal_minutes <= 0) {
    return(piecewise_score(delay_minutes, 3, 8, 20))
  }
  delay_ratio <- delay_minutes / max(normal_minutes, 1)
  pmax(piecewise_score(delay_minutes, 3, 8, 20), piecewise_score(delay_ratio, 0.10, 0.30, 1.00), na.rm = TRUE)
}

# Returns the canonical empty CRS-4326 sf with all road overlay columns - used as fallback when 511WI feeds yield no rows.
empty_road_overlay_sf <- function() {
  sf::st_sf(
    road_id = character(0),
    road_name = character(0),
    road_class = character(0),
    route_tier = character(0),
    base_speed_mph = numeric(0),
    susceptibility = numeric(0),
    driving_total_risk = numeric(0),
    road_color = character(0),
    road_opacity = numeric(0),
    road_weight = numeric(0),
    driving_risk_label = character(0),
    driving_reason_text = character(0),
    dominant_zip = character(0),
    road_source = character(0),
    official_cause_text = character(0),
    popup_label = character(0),
    geometry = sf::st_sfc(crs = 4326)
  )
}

# Why: rbind across road overlays from different sources requires a common
# column schema; we backfill any missing columns to that schema.
# What: returns x with the canonical road-overlay columns present (numeric
# defaults to 0, character defaults to "") and ordered consistently.
# How: lists required columns, fills any missing column with the right
# typed default of length nrow(x), and reorders.
# When: called before rbind in build_driving_roads_overlay (modeled +
# WI511 sources merged into one layer).
# Impact: a column added to one source but not handled here causes silent
# drop or rbind type-mismatch warnings.
standardize_road_overlay_sf <- function(x) {
  if (is.null(x) || nrow(x) == 0) return(empty_road_overlay_sf())
  needed <- c("road_id", "road_name", "road_class", "route_tier", "base_speed_mph", "susceptibility", "driving_total_risk", "road_color", "road_opacity", "road_weight", "driving_risk_label", "driving_reason_text", "dominant_zip", "road_source", "official_cause_text", "popup_label")
  for (nm in needed) {
    if (!nm %in% names(x)) {
      x[[nm]] <- if (nm %in% c("base_speed_mph", "susceptibility", "driving_total_risk", "road_opacity", "road_weight")) numeric(nrow(x)) else character(nrow(x))
    }
  }
  x[, c(needed, "geometry"), drop = FALSE]
}

# Why: turn the WI511 winter-road status feed into a styled sf overlay we
# can stack on top of the modeled driving risk.
# What: returns an sf with road geometry and per-segment scores/popups, or
# empty_road_overlay_sf when the API key is missing or no rows decode.
# How: hits WI511_WINTER_ROADS_URL with the API key, decodes each entry's
# polyline, scores via score_511_winter_status, builds a popup, caches.
# When: called by the WI511 transport pipeline; cached for ALERT_TTL_SECONDS.
# Impact: missing key falls through to empty overlay; a malformed polyline
# silently drops that segment from the layer.
fetch_511_winter_roads_live <- function() {
  key <- "wi511-winter-live"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  if (!has_wi511_key()) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  payload <- tryCatch(
    http_json_query(WI511_WINTER_ROADS_URL, query = list(key = WI511_API_KEY, format = "json")),
    error = function(e) NULL
  )
  items <- if (is.data.frame(payload)) split(payload, seq_len(nrow(payload))) else (payload %||% list())
  rows <- vector("list", 0)
  geoms <- list()
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      road_id <- extract_named_character(it, c("Id", "ID", "id"), default = NA_character_)
      road_name <- extract_named_character(it, c("RoadwayName", "roadwayName", "RoadName"), default = "Wisconsin road")
      status <- extract_named_character(it, c("OverallStatus", "Overall Status", "Status"), default = "")
      location_desc <- extract_named_character(it, c("LocationDescription", "Location", "Description"), default = NA_character_)
      area_name <- extract_named_character(it, c("AreaName", "Area", "Region"), default = NA_character_)
      encoded <- extract_named_character(it, c("EncodedPolyline", "Polyline", "encodedPolyline"), default = "")
      updated_txt <- format_unix_time_or_na(extract_named_numeric_any(it, c("LastUpdated", "Updated", "LastUpdate")))
      geom <- linestring_sfc_from_matrix(decode_polyline_matrix(encoded))
      if (length(geom) == 0 || isTRUE(sf::st_is_empty(geom[[1]]))) next
      score_live <- score_511_winter_status(status)
      rows[[length(rows) + 1L]] <- data.frame(
        road_id = paste0("511winter-", road_id %||% length(rows)),
        road_name = road_name,
        road_class = "511WI winter",
        driving_total_risk = score_live,
        road_color = NA_character_,
        road_opacity = NA_real_,
        road_weight = NA_real_,
        driving_risk_label = NA_character_,
        driving_reason_text = if (nzchar(status)) sprintf("511WI winter road status: %s.", status) else "511WI winter road condition indicates elevated travel risk.",
        dominant_zip = NA_character_,
        road_source = "511WI winter roads",
        popup_label = sprintf(
          paste0('<div style="min-width:260px;">', '<div style="font-weight:700; margin-bottom:0.35rem;">%s</div>', '<div><strong>Source:</strong> 511WI winter roads</div>', '<div><strong>Status:</strong> %s</div>', '<div><strong>Location:</strong> %s</div>', '<div><strong>Area:</strong> %s</div>', '<div><strong>Updated:</strong> %s</div>', '</div>'),
          escape_html(road_name),
          escape_html(ifelse(nzchar(status), status, "Unknown")),
          escape_html(ifelse(is.na(location_desc), "N/A", location_desc)),
          escape_html(ifelse(is.na(area_name), "N/A", area_name)),
          escape_html(ifelse(is.na(updated_txt), "N/A", updated_txt))
        ),
        stringsAsFactors = FALSE
      )
      geoms[[length(geoms) + 1L]] <- geom[[1]]
    }
  }
  if (length(rows) == 0) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  out <- sf::st_sf(dplyr::bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

# Why: surface congestion-driven driving risk from the WI511 travel-time
# feed, complementing the winter-road and event feeds.
# What: returns an sf overlay of route segments with delay-based scores and
# popups, or empty when no key/payload is available.
# How: parses each travel-time entry, decodes start/waypoints/end into a
# linestring, computes score via score_511_travel_delay, drops zero-score
# rows, caches.
# When: called by the WI511 transport pipeline.
# Impact: this is the only source of "this route is slower than usual" on
# the map; outages collapse the layer entirely.
fetch_511_travel_times_live <- function() {
  key <- "wi511-traveltimes-live"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  if (!has_wi511_key()) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  payload <- tryCatch(
    http_json_query(WI511_TRAVEL_TIMES_URL, query = list(key = WI511_API_KEY, format = "json")),
    error = function(e) NULL
  )
  items <- if (is.data.frame(payload)) split(payload, seq_len(nrow(payload))) else (payload %||% list())
  rows <- vector("list", 0)
  geoms <- list()
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      road_id <- extract_named_character(it, c("Id", "ID", "id"), default = NA_character_)
      road_name <- extract_named_character(it, c("RoadwayName", "roadwayName", "RoadName"), default = "Wisconsin route")
      description <- extract_named_character(it, c("Description", "LocationDescription"), default = NA_character_)
      region <- extract_named_character(it, c("Region", "AreaName"), default = NA_character_)
      delay_minutes <- extract_named_numeric_any(it, c("Delay", "delay"))
      normal_minutes <- extract_named_numeric_any(it, c("NormalTime", "normalTime"))
      current_minutes <- extract_named_numeric_any(it, c("CurrentTime", "currentTime"))
      start_lat <- extract_named_numeric_any(it, c("StartLatitude", "startLatitude"))
      start_lon <- extract_named_numeric_any(it, c("StartLongitude", "startLongitude"))
      end_lat <- extract_named_numeric_any(it, c("EndLatitude", "endLatitude"))
      end_lon <- extract_named_numeric_any(it, c("EndLongitude", "endLongitude"))
      waypoints <- extract_named_value(it, c("Waypoints", "waypoints"), default = list())
      geom <- linestring_sfc_from_waypoints(waypoints, start_lon = start_lon, start_lat = start_lat, end_lon = end_lon, end_lat = end_lat)
      if (length(geom) == 0 || isTRUE(sf::st_is_empty(geom[[1]]))) next
      score_live <- score_511_travel_delay(delay_minutes, normal_minutes, current_minutes)
      if (!is.finite(score_live) || score_live <= 0) next
      rows[[length(rows) + 1L]] <- data.frame(
        road_id = paste0("511tt-", road_id %||% length(rows)),
        road_name = road_name,
        road_class = "511WI travel time",
        driving_total_risk = score_live,
        road_color = NA_character_,
        road_opacity = NA_real_,
        road_weight = NA_real_,
        driving_risk_label = NA_character_,
        driving_reason_text = sprintf("511WI travel delay elevated risk by %.1f minutes over normal.", ifelse(is.finite(delay_minutes), pmax(0, delay_minutes), 0)),
        dominant_zip = NA_character_,
        road_source = "511WI travel times",
        popup_label = sprintf(
          paste0('<div style="min-width:260px;">', '<div style="font-weight:700; margin-bottom:0.35rem;">%s</div>', '<div><strong>Source:</strong> 511WI travel times</div>', '<div><strong>Description:</strong> %s</div>', '<div><strong>Region:</strong> %s</div>', '<div><strong>Current time:</strong> %s min</div>', '<div><strong>Normal time:</strong> %s min</div>', '<div><strong>Delay:</strong> %s min</div>', '</div>'),
          escape_html(road_name),
          escape_html(ifelse(is.na(description), "N/A", description)),
          escape_html(ifelse(is.na(region), "N/A", region)),
          escape_html(ifelse(is.finite(current_minutes), sprintf("%.1f", current_minutes), "N/A")),
          escape_html(ifelse(is.finite(normal_minutes), sprintf("%.1f", normal_minutes), "N/A")),
          escape_html(ifelse(is.finite(delay_minutes), sprintf("%.1f", delay_minutes), "N/A"))
        ),
        stringsAsFactors = FALSE
      )
      geoms[[length(geoms) + 1L]] <- geom[[1]]
    }
  }
  if (length(rows) == 0) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  out <- sf::st_sf(dplyr::bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

# Maps WI511 incident text + severity + closure flag to a 0..1 risk via keyword priority (closure -> 1.0, accident -> 0.75, roadwork -> 0.45, etc.).
score_511_event_risk <- function(description = "", event_type = "", event_subtype = "", severity = "", lanes_affected = "", is_full_closure = FALSE) {
  text <- tolower(trimws(paste(description, event_type, event_subtype, severity, lanes_affected, collapse = " | ")))
  if (isTRUE(is_full_closure) || grepl("all lanes closed|full closure|closed|closure", text)) return(1.00)
  if (grepl("jackknife|hazmat|fire|washout|bridge|sinkhole|flood", text)) return(0.95)
  if (grepl("accident|crash|incident|overturned|disabled vehicle", text)) return(0.75)
  if (grepl("roadwork|construction|maintenance", text)) return(0.45)
  if (grepl("lane closed|shoulder closed|reduced to", text)) return(0.40)
  sev <- tolower(trimws(safe_string(severity)))
  if (sev %in% c("major", "high", "severe")) return(0.80)
  if (sev %in% c("medium", "moderate")) return(0.55)
  if (sev %in% c("minor", "low")) return(0.30)
  0.20
}

# Why: transform the WI511 events feed (crashes, hazmat, closures) into a
# styled sf overlay with rich popup details.
# What: returns an sf with road geometries (decoded polyline, detour
# polyline, or two-point fallback) plus scores and popup HTML.
# How: per event, decodes the primary polyline (or detour, or end-points),
# scores via score_511_event_risk, drops zero-score rows, caches.
# When: invoked by the WI511 transport pipeline alongside winter and travel.
# Impact: this layer carries the "incident" side of road risk; missing it
# loses the most actionable real-time information for drivers.
fetch_511_events_live <- function() {
  key <- "wi511-events-live"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  if (!has_wi511_key()) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  payload <- tryCatch(
    http_json_query(WI511_EVENTS_URL, query = list(key = WI511_API_KEY, format = "json")),
    error = function(e) NULL
  )
  items <- if (is.data.frame(payload)) split(payload, seq_len(nrow(payload))) else (payload %||% list())
  rows <- vector("list", 0)
  geoms <- list()
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      road_id <- extract_named_character(it, c("ID", "Id", "id"), default = NA_character_)
      road_name <- extract_named_character(it, c("RoadwayName", "roadwayName", "RoadName"), default = "Wisconsin roadway")
      description <- extract_named_character(it, c("Description", "Comment", "Location"), default = "")
      event_type <- extract_named_character(it, c("EventType", "Type"), default = "")
      event_subtype <- extract_named_character(it, c("EventSubType", "SubType"), default = "")
      severity <- extract_named_character(it, c("Severity", "severity"), default = "")
      lanes_affected <- extract_named_character(it, c("LanesAffected", "LanesStatus"), default = "")
      is_full_closure <- isTRUE(extract_named_value(it, c("IsFullClosure", "FullClosure"), default = FALSE))
      county <- extract_named_character(it, c("County", "CountyName"), default = NA_character_)
      encoded <- extract_named_character(it, c("EncodedPolyline", "MapEncodedPolyline", "Polyline"), default = "")
      detour_encoded <- extract_named_character(it, c("DetourPolyline", "detourPolyline"), default = "")
      updated_txt <- format_unix_time_or_na(extract_named_numeric_any(it, c("LastUpdated", "Updated")))
      lat1 <- extract_named_numeric_any(it, c("Latitude", "latitude"))
      lon1 <- extract_named_numeric_any(it, c("Longitude", "longitude"))
      lat2 <- extract_named_numeric_any(it, c("LatitudeSecondary", "lat2"))
      lon2 <- extract_named_numeric_any(it, c("LongitudeSecondary", "lon2"))
      geom <- linestring_sfc_from_matrix(decode_polyline_matrix(encoded))
      if ((length(geom) == 0 || isTRUE(sf::st_is_empty(geom[[1]]))) && nzchar(detour_encoded)) {
        geom <- linestring_sfc_from_matrix(decode_polyline_matrix(detour_encoded))
      }
      if (length(geom) == 0 || isTRUE(sf::st_is_empty(geom[[1]]))) {
        coords <- matrix(c(lon1, lat1, lon2, lat2), ncol = 2, byrow = TRUE)
        coords <- coords[apply(coords, 1, function(v) all(is.finite(v))), , drop = FALSE]
        if (nrow(coords) == 1) {
          geom <- sf::st_sfc(sf::st_linestring(rbind(coords[1, ], coords[1, ])), crs = 4326)
        } else if (nrow(coords) >= 2) {
          geom <- sf::st_sfc(sf::st_linestring(coords), crs = 4326)
        }
      }
      if (length(geom) == 0 || isTRUE(sf::st_is_empty(geom[[1]]))) next
      score_live <- score_511_event_risk(description, event_type, event_subtype, severity, lanes_affected, is_full_closure)
      if (!is.finite(score_live) || score_live <= 0) next
      rows[[length(rows) + 1L]] <- data.frame(
        road_id = paste0("511event-", road_id %||% length(rows)),
        road_name = road_name,
        road_class = "511WI event",
        driving_total_risk = score_live,
        road_color = NA_character_,
        road_opacity = NA_real_,
        road_weight = NA_real_,
        driving_risk_label = NA_character_,
        driving_reason_text = sprintf("511WI event: %s", ifelse(nzchar(description), description, paste(event_type, event_subtype))),
        dominant_zip = NA_character_,
        road_source = "511WI events",
        popup_label = sprintf(
          paste0('<div style="min-width:260px;">', '<div style="font-weight:700; margin-bottom:0.35rem;">%s</div>', '<div><strong>Source:</strong> 511WI events</div>', '<div><strong>Event type:</strong> %s</div>', '<div><strong>Description:</strong> %s</div>', '<div><strong>Lanes:</strong> %s</div>', '<div><strong>County:</strong> %s</div>', '<div><strong>Updated:</strong> %s</div>', '</div>'),
          escape_html(road_name),
          escape_html(ifelse(nzchar(event_type), event_type, "Event")),
          escape_html(ifelse(nzchar(description), description, "N/A")),
          escape_html(ifelse(nzchar(lanes_affected), lanes_affected, "N/A")),
          escape_html(ifelse(is.na(county), "N/A", county)),
          escape_html(ifelse(is.na(updated_txt), "N/A", updated_txt))
        ),
        stringsAsFactors = FALSE
      )
      geoms[[length(geoms) + 1L]] <- geom[[1]]
    }
  }
  if (length(rows) == 0) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  out <- sf::st_sf(dplyr::bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

# Maps WI511 alert message + notes + flags to 0..1 - keywords drive the base score, high_importance/send_notification add small bumps.
score_511_alert_risk <- function(message = "", notes = "", high_importance = FALSE, send_notification = FALSE) {
  text <- tolower(trimws(paste(message, notes, collapse = " | ")))
  if (!nzchar(text)) return(0)
  score <- 0.20
  if (grepl("closed|closure|blocked|impassable|all lanes|detour", text)) score <- max(score, 0.90)
  if (grepl("flood|washout|bridge|sinkhole|fire|hazmat|jackknife", text)) score <- max(score, 0.95)
  if (grepl("crash|incident|disabled|overturned|lane closed|restriction|delay", text)) score <- max(score, 0.60)
  if (grepl("roadwork|construction|maintenance", text)) score <- max(score, 0.40)
  if (isTRUE(high_importance)) score <- min(1, score + 0.10)
  if (isTRUE(send_notification)) score <- min(1, score + 0.05)
  pmin(1, score)
}

# Returns the unique 5-digit ZIP codes mentioned in text that exist in wi_zctas$zipcode.
extract_zipcodes_from_text <- function(text) {
  txt <- safe_string(text)
  hits <- unique(unlist(regmatches(txt, gregexpr("\\b[0-9]{5}\\b", txt, perl = TRUE)), use.names = FALSE))
  hits <- hits[hits %in% wi_zctas$zipcode]
  unique(as.character(hits))
}

# Returns the unique zipcodes belonging to any WI county whose normalised name appears as a whole word in text.
extract_county_zipcodes_from_text <- function(text) {
  txt <- normalize_match_text(text)
  if (!nzchar(txt)) return(character(0))
  county_names <- unique(as.character(wi_counties$NAME))
  matched <- county_names[vapply(
    county_names,
    function(nm) {
      nm_norm <- normalize_match_text(nm)
      nzchar(nm_norm) && grepl(paste0("\\b", regex_escape(nm_norm), "\\b"), txt, perl = TRUE)
    },
    logical(1)
  )]
  if (length(matched) == 0) return(character(0))
  unique(as.character(wi_zctas$zipcode[wi_zctas$county_name %in% matched]))
}

# Returns the unique zipcodes that intersect any place polygon whose normalised name appears as a whole word in text.
extract_place_zipcodes_from_text <- function(text) {
  txt <- normalize_match_text(text)
  if (!nzchar(txt)) return(character(0))
  places <- load_places()
  if (nrow(places) == 0 || !"NAME" %in% names(places)) return(character(0))
  place_names <- unique(as.character(places$NAME))
  matched <- place_names[vapply(
    place_names,
    function(nm) {
      nm_norm <- normalize_match_text(nm)
      nzchar(nm_norm) && grepl(paste0("\\b", regex_escape(nm_norm), "\\b"), txt, perl = TRUE)
    },
    logical(1)
  )]
  if (length(matched) == 0) return(character(0))
  place_hits <- places[places$NAME %in% matched, , drop = FALSE]
  inter <- suppressWarnings(sf::st_intersects(wi_zctas, place_hits))
  unique(as.character(wi_zctas$zipcode[lengths(inter) > 0]))
}

# Uppercases x, replaces non-alphanumerics with single spaces, and collapses whitespace - used to canonicalise highway tokens.
normalize_route_text <- function(x) {
  trimws(gsub("\\s+", " ", gsub("[^A-Za-z0-9]+", " ", toupper(safe_string(x)))))
}

# Why: WI511 alerts often mention "I-94" or "STH 29" but no county or ZIP;
# we map those tokens to the ZIP set that touches that highway.
# What: returns a unique character vector of zipcodes touching any
# matching road (capped at max_tokens roads to avoid blow-up).
# How: regex-extracts I-/US-/WI-/STH-/HWY- tokens, normalises each, fuzzy
# matches against load_wi_roads()$road_name (with HIGHWAY/STH aliasing),
# and pulls the precomputed road_zip lookup entries.
# When: called by resolve_511_region_zipcodes for each WI511 alert.
# Impact: a missing pattern (e.g., a future "CTH-X" county-trunk format)
# silently drops the alert from the affected ZIPs.
extract_roadway_zipcodes_from_text <- function(text, max_tokens = 8L) {
  txt <- toupper(safe_string(text))
  if (!nzchar(txt)) return(character(0))
  patt <- "\\b(?:I\\s*-?\\s*\\d+|US\\s*-?\\s*\\d+|WI\\s*-?\\s*\\d+|STH\\s*-?\\s*\\d+|HWY\\s*-?\\s*\\d+|HIGHWAY\\s+\\d+)\\b"
  raw_tokens <- unique(unlist(regmatches(txt, gregexpr(patt, txt, perl = TRUE)), use.names = FALSE))
  if (length(raw_tokens) == 0) return(character(0))
  roads <- load_wi_roads()
  lookup <- load_road_zip_lookup()
  if (nrow(roads) == 0 || length(lookup) == 0) return(character(0))
  road_norm <- normalize_route_text(roads$road_name)
  zip_hits <- character(0)
  for (tok in utils::head(raw_tokens, max_tokens)) {
    tok_norm <- normalize_route_text(tok)
    if (!nzchar(tok_norm)) next
    tok_alt <- gsub("\\bHIGHWAY\\b", "HWY", tok_norm)
    tok_alt2 <- gsub("\\bSTH\\b", "WI", tok_norm)
    idx <- grepl(paste0("(^| )", regex_escape(tok_norm), "( |$)"), road_norm, perl = TRUE) |
      grepl(paste0("(^| )", regex_escape(tok_alt), "( |$)"), road_norm, perl = TRUE) |
      grepl(paste0("(^| )", regex_escape(tok_alt2), "( |$)"), road_norm, perl = TRUE)
    if (!any(idx)) next
    zip_hits <- c(zip_hits, unlist(lookup[roads$road_id[idx]], use.names = FALSE))
  }
  zip_hits <- unique(as.character(zip_hits))
  zip_hits[zip_hits %in% wi_zctas$zipcode]
}

# Why: WI511 uses informal regional names ("northeastern", "south central")
# we want to translate into ZIP sets via a curated county-group table.
# What: returns the unique zipcodes for every county_group implied by the
# input tokens.
# How: hardcoded county_groups + alias_to_group tables; tokens hit the
# alias map and the matched group's counties feed wi_zctas$county_name.
# When: called by resolve_511_region_zipcodes.
# Impact: missing aliases here mean an alert tagged with a regional name
# but no specific roadway/county/place silently fails to map.
region_alias_zipcodes <- function(region_tokens) {
  tokens <- tolower(trimws(as.character(region_tokens %||% character(0))))
  tokens <- tokens[nzchar(tokens)]
  if (length(tokens) == 0) return(character(0))
  county_groups <- list(
    statewide = unique(as.character(wi_zctas$zipcode)),
    northwestern = c("Douglas", "Bayfield", "Ashland", "Iron", "Burnett", "Washburn", "Sawyer", "Price", "Rusk", "Barron", "Polk", "St. Croix"),
    northeastern = c("Door", "Kewaunee", "Brown", "Oconto", "Marinette", "Florence", "Forest", "Langlade", "Lincoln", "Oneida", "Vilas", "Menominee", "Shawano"),
    southwestern = c("Dane", "Green", "Rock", "Iowa", "Lafayette", "Grant", "Crawford", "Richland", "Sauk", "Columbia", "Juneau", "Vernon"),
    southeastern = c("Milwaukee", "Ozaukee", "Washington", "Waukesha", "Racine", "Kenosha", "Walworth", "Jefferson", "Dodge", "Sheboygan"),
    central = c("Wood", "Portage", "Marathon", "Adams", "Waushara", "Waupaca", "Outagamie", "Winnebago", "Fond du Lac", "Green Lake", "Marquette", "Clark", "Taylor")
  )
  alias_to_group <- c(
    statewide = "statewide",
    "state of wisconsin" = "statewide",
    wisconsin = "statewide",
    northwest = "northwestern",
    northwestern = "northwestern",
    "north west" = "northwestern",
    northeast = "northeastern",
    northeastern = "northeastern",
    "north east" = "northeastern",
    southwest = "southwestern",
    southwestern = "southwestern",
    "south west" = "southwestern",
    southeast = "southeastern",
    southeastern = "southeastern",
    "south east" = "southeastern",
    central = "central",
    "north central" = "central",
    "south central" = "southwestern"
  )
  out <- character(0)
  for (tok in tokens) {
    group <- alias_to_group[[tok]] %||% NA_character_
    if (!is.na(group)) {
      counties <- county_groups[[group]] %||% character(0)
      out <- c(out, as.character(wi_zctas$zipcode[wi_zctas$county_name %in% counties]))
    }
  }
  unique(out)
}

# Combines all four extractors (zip / county / place / roadway / region alias) to translate the regions string into a unique ZIP set.
resolve_511_region_zipcodes <- function(regions_text) {
  txt <- safe_string(regions_text)
  if (!nzchar(txt)) return(character(0))
  tokens <- unique(trimws(unlist(strsplit(gsub("[;|/]+", ",", tolower(txt)), ","), use.names = FALSE)))
  tokens <- tokens[nzchar(tokens)]
  unique(c(
    extract_zipcodes_from_text(txt),
    extract_county_zipcodes_from_text(txt),
    extract_place_zipcodes_from_text(txt),
    extract_roadway_zipcodes_from_text(txt),
    region_alias_zipcodes(tokens)
  ))
}

# Maps a dynamic message-sign text to a 0..1 risk via keyword priority (closure 0.90, hazard 0.95, crash 0.60, winter 0.58, default 0.18).
score_511_message_sign_risk <- function(message_text = "") {
  txt <- tolower(trimws(safe_string(message_text)))
  if (!nzchar(txt) || identical(txt, "no_message")) return(0)
  score <- 0.18
  if (grepl("closed|closure|detour|blocked|do not use|exit closed|ramp closed", txt)) score <- max(score, 0.90)
  if (grepl("flood|washout|bridge|sinkhole|hazmat|fire|jackknife", txt)) score <- max(score, 0.95)
  if (grepl("crash|incident|disabled|lane closed|restriction|delay|congestion|slow traffic", txt)) score <- max(score, 0.60)
  if (grepl("slippery|ice|snow|winter|blowing snow|reduced visibility|fog", txt)) score <- max(score, 0.58)
  pmin(1, score)
}

# Why: dynamic message signs often surface road conditions before official
# events feeds; treat them as ZIP-and-road-level point hazards.
# What: returns an sf of POINT geometries with sign_id, road_name, county,
# direction, message_text, sign_score, and reason text.
# How: hits WI511_MESSAGE_SIGNS_URL, parses each entry, builds the
# message text, scores via score_511_message_sign_risk, drops zero-score
# rows, builds an sf of points.
# When: called by compute_511_message_sign_zip_signal and the road-overlay
# builder.
# Impact: the scoring keyword list is the only filter against noise (e.g.,
# "TURN HEADLIGHTS ON" type signs); too inclusive lights up ambient signs.
fetch_511_message_signs_live <- function() {
  key <- "wi511-message-signs-live"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  if (!has_wi511_key()) {
    out <- sf::st_sf(sign_id = character(0), road_name = character(0), county = character(0), direction = character(0), message_text = character(0), sign_score = numeric(0), sign_reason_text = character(0), geometry = sf::st_sfc(crs = 4326))
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  payload <- safely(http_json_query(WI511_MESSAGE_SIGNS_URL, query = list(key = WI511_API_KEY, format = "json")))
  items <- if (is.data.frame(payload)) split(payload, seq_len(nrow(payload))) else (payload %||% list())
  rows <- vector("list", 0)
  geoms <- vector("list", 0)
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      lat <- extract_named_numeric(it, c("Latitude", "latitude", "Lat", "lat"), default = NA_real_)
      lon <- extract_named_numeric(it, c("Longitude", "longitude", "Lon", "lon"), default = NA_real_)
      if (!is.finite(lat) || !is.finite(lon)) next
      sign_id <- extract_named_character(it, c("Id", "ID", "id"), default = NA_character_)
      name <- extract_named_character(it, c("Name", "name"), default = "511WI message sign")
      road_name <- extract_named_character(it, c("Roadway", "RoadwayName", "roadway"), default = name)
      county <- extract_named_character(it, c("County", "county"), default = NA_character_)
      direction <- extract_named_character(it, c("DirectionOfTravel", "directionOfTravel", "Direction"), default = NA_character_)
      msgs_obj <- extract_named_value(it, c("Messages", "messages"), default = character(0))
      msgs <- if (is.list(msgs_obj)) unlist(msgs_obj, use.names = FALSE) else as.character(msgs_obj %||% character(0))
      msgs <- msgs[nzchar(trimws(as.character(msgs)))]
      if (length(msgs) == 0) msgs <- "NO_MESSAGE"
      msg_text <- paste(msgs, collapse = " | ")
      score_live <- score_511_message_sign_risk(msg_text)
      if (!is.finite(score_live) || score_live <= 0) next
      rows[[length(rows) + 1L]] <- data.frame(
        sign_id = as.character(sign_id %||% paste0("511msg-", length(rows) + 1L)),
        road_name = as.character(road_name %||% name %||% "511WI message sign"),
        county = as.character(county %||% NA_character_),
        direction = as.character(direction %||% NA_character_),
        message_text = safe_string(msg_text),
        sign_score = score_live,
        sign_reason_text = sprintf("511WI message sign: %s", ifelse(nzchar(msg_text), msg_text, name)),
        stringsAsFactors = FALSE
      )
      geoms[[length(geoms) + 1L]] <- sf::st_point(c(lon, lat))
    }
  }
  out <- if (length(rows) == 0) {
    sf::st_sf(sign_id = character(0), road_name = character(0), county = character(0), direction = character(0), message_text = character(0), sign_score = numeric(0), sign_reason_text = character(0), geometry = sf::st_sfc(crs = 4326))
  } else {
    sf::st_sf(dplyr::bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
  }
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

# Why: dynamic message signs sit at points; we want a per-ZIP score that
# decays with distance and rewards same-roadway matches.
# What: returns list(scores, reasons) keyed by ZIP for the given horizon.
# How: projects to 5070, finds signs within 18km of each ZIP centroid,
# multiplies sign_score by exp(-d/7000), boosts 1.18x when the sign's
# roadway tokens hit the ZIP's roadway list; keeps the per-ZIP max.
# When: called by the WI511 transport pipeline; cached by horizon.
# Impact: the 18km radius and 7km decay constant set how far a single sign
# spreads its influence on the map.
compute_511_message_sign_zip_signal <- function(horizon_key = "live") {
  cache_name <- paste0("wi511-message-sign-zip-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  signs <- fetch_511_message_signs_live()
  if (nrow(signs) == 0) {
    out <- list(scores = out_scores, reasons = out_reasons)
    cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
    return(out)
  }
  if (!identical(horizon_key, "live")) signs$sign_score <- apply_live_decay(signs$sign_score, horizon_key, half_life_hours = 8)
  zip_pts_proj <- wi_zip_points_proj
  signs_proj <- suppressWarnings(sf::st_transform(signs, 5070))
  hits <- suppressWarnings(sf::st_is_within_distance(zip_pts_proj, signs_proj, dist = 18000))
  for (i in seq_along(hits)) {
    idx <- unique(as.integer(hits[[i]]))
    if (length(idx) == 0) next
    d <- safe_numeric(sf::st_distance(zip_pts_proj[i, ], signs_proj[idx, ]))
    if (length(d) == 0) next
    d[!is.finite(d)] <- 18000
    road_hits <- vapply(idx, function(j) wi_zctas$zipcode[i] %in% (extract_roadway_zipcodes_from_text(signs$road_name[j], max_tokens = 2L) %||% character(0)), logical(1))
    road_boost <- ifelse(road_hits, 1.18, 1.00)
    local_scores <- pmin(1, signs$sign_score[idx] * exp(-pmax(d, 0) / 7000) * road_boost)
    if (!any(is.finite(local_scores) & local_scores > 0)) next
    best <- which.max(local_scores)[1]
    out_scores[i] <- local_scores[best]
    out_reasons[i] <- paste0(as.character(signs$sign_reason_text[idx[best]]), " Nearby dynamic-message-sign conditions are influencing this ZIP.")
  }
  out <- list(scores = out_scores, reasons = out_reasons)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

# Why: roads need their own message-sign signal (separate from the per-ZIP
# version) so the road overlay can pick up sign-driven hazards.
# What: returns list(scores, reasons, sources) keyed by road_id.
# How: projects to 5070, finds signs within 12km of each road, applies
# distance decay (4.5km scale) and 1.25x same-name boost, keeps per-road
# max.
# When: called by the road-overlay builder and compute_511_road_proximity_signal.
# Impact: the radii here are tighter than the per-zip version because
# roads are linear features.
compute_511_message_sign_road_signal <- function(horizon_key = "live") {
  cache_name <- paste0("wi511-message-sign-road-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  roads <- load_wi_roads()
  out_scores <- stats::setNames(rep(0, nrow(roads)), roads$road_id)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(roads)), roads$road_id)
  out_sources <- stats::setNames(rep(NA_character_, nrow(roads)), roads$road_id)
  signs <- fetch_511_message_signs_live()
  if (nrow(roads) == 0 || nrow(signs) == 0) {
    out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
    cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
    return(out)
  }
  if (!identical(horizon_key, "live")) signs$sign_score <- apply_live_decay(signs$sign_score, horizon_key, half_life_hours = 8)
  roads_proj <- suppressWarnings(sf::st_transform(roads, 5070))
  signs_proj <- suppressWarnings(sf::st_transform(signs, 5070))
  hits <- suppressWarnings(sf::st_is_within_distance(roads_proj, signs_proj, dist = 12000))
  road_norm <- normalize_route_text(roads$road_name)
  sign_norm <- normalize_route_text(signs$road_name)
  for (i in seq_along(hits)) {
    idx <- unique(as.integer(hits[[i]]))
    if (length(idx) == 0) next
    d <- safe_numeric(sf::st_distance(roads_proj[i, ], signs_proj[idx, ]))
    if (length(d) == 0) next
    d[!is.finite(d)] <- 12000
    name_boost <- ifelse(sign_norm[idx] == road_norm[i] & nzchar(road_norm[i]), 1.25, 1.00)
    local_scores <- pmin(1, signs$sign_score[idx] * exp(-pmax(d, 0) / 4500) * name_boost)
    if (!any(is.finite(local_scores) & local_scores > 0)) next
    best <- which.max(local_scores)[1]
    out_scores[i] <- local_scores[best]
    out_reasons[i] <- paste0(as.character(signs$sign_reason_text[idx[best]]), " Nearby dynamic-message-sign conditions are influencing this road.")
    out_sources[i] <- "511WI message signs"
  }
  out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

# Why: WI511 publishes prose alerts (no inherent geometry) so we score them
# generically and let downstream code resolve their geographies from text.
# What: returns a data.frame(alert_id, score, message, notes,
# high_importance, send_notification, regions, reason_text), or empty
# data.frame when no key/payload.
# How: walks the alerts feed, applies score_511_alert_risk, drops
# zero-score rows, caches.
# When: called by compute_511_alert_zip_signal.
# Impact: a missing key returns empty data and the alert layer goes dark
# without a visible error.
fetch_511_alerts_live <- function() {
  key <- "wi511-alerts-live"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  if (!has_wi511_key()) {
    out <- data.frame(alert_id = character(), score = numeric(), message = character(), notes = character(), high_importance = logical(), send_notification = logical(), regions = character(), reason_text = character(), stringsAsFactors = FALSE)
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  payload <- safely(
    http_json_query(WI511_ALERTS_URL, query = list(key = WI511_API_KEY, format = "json"))
  )
  items <- if (is.data.frame(payload)) split(payload, seq_len(nrow(payload))) else (payload %||% list())
  rows <- vector("list", 0)
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      message <- extract_named_character(it, c("Message", "message"), default = "")
      notes <- extract_named_character(it, c("Notes", "notes"), default = "")
      high_importance <- isTRUE(extract_named_value(it, c("HighImportance", "highImportance"), default = FALSE))
      send_notification <- isTRUE(extract_named_value(it, c("SendNotification", "sendNotification"), default = FALSE))
      alert_id <- extract_named_character(it, c("Id", "ID", "id"), default = NA_character_)
      regions_obj <- extract_named_value(it, c("Regions", "regions"), default = character(0))
      regions <- if (is.list(regions_obj)) paste(unlist(regions_obj, use.names = FALSE), collapse = ", ") else safe_string(regions_obj)
      score <- score_511_alert_risk(message, notes, high_importance = high_importance, send_notification = send_notification)
      if (!is.finite(score) || score <= 0) next
      rows[[length(rows) + 1L]] <- data.frame(
        alert_id = as.character(alert_id %||% paste0("511alert-", length(rows) + 1L)),
        score = score,
        message = safe_string(message),
        notes = safe_string(notes),
        high_importance = high_importance,
        send_notification = send_notification,
        regions = safe_string(regions),
        reason_text = sprintf("511WI alert: %s", ifelse(nzchar(message), message, "Traffic alert")),
        stringsAsFactors = FALSE
      )
    }
  }
  out <- if (length(rows) == 0) data.frame(alert_id = character(), score = numeric(), message = character(), notes = character(), high_importance = logical(), send_notification = logical(), regions = character(), reason_text = character(), stringsAsFactors = FALSE) else dplyr::bind_rows(rows)
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

# Why: WI511 alerts need a per-ZIP score plus reason-text join even though
# the alerts have no native geometry.
# What: returns list(scores, reasons) keyed by zipcode; reasons hold the
# best matching alert's reason_text.
# How: per alert, runs all five extractors (zip/county/place/roadway/region)
# on the message+notes+regions blob; falls back to statewide at half score
# when high_importance and nothing matched; takes per-zip max.
# When: called by the WI511 transport pipeline.
# Impact: the high-importance fallback prevents alerts with sparse text
# from being silenced; can over-broadcast if mis-tagged.
compute_511_alert_zip_signal <- function(horizon_key = "live") {
  cache_name <- paste0("wi511-alert-zip-signal-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  alerts <- fetch_511_alerts_live()
  if (nrow(alerts) == 0) {
    out <- list(scores = out_scores, reasons = out_reasons)
    cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
    return(out)
  }
  for (i in seq_len(nrow(alerts))) {
    text_blob <- paste(alerts$message[i], alerts$notes[i], alerts$regions[i], collapse = " | ")
    zipcodes <- unique(c(
      extract_zipcodes_from_text(text_blob),
      extract_county_zipcodes_from_text(text_blob),
      extract_place_zipcodes_from_text(text_blob),
      extract_roadway_zipcodes_from_text(text_blob),
      resolve_511_region_zipcodes(alerts$regions[i])
    ))
    score <- alerts$score[i]
    if (!identical(horizon_key, "live")) {
      score <- apply_live_decay(score, horizon_key, half_life_hours = 10)
    }
    if (!length(zipcodes) && isTRUE(alerts$high_importance[i])) {
      zipcodes <- wi_zctas$zipcode
      score <- max(score * 0.45, 0.18)
    }
    if (!length(zipcodes)) next
    zipcodes <- unique(as.character(stats::na.omit(zipcodes)))
    idx <- match(zipcodes, wi_zctas$zipcode)
    idx <- idx[is.finite(idx)]
    if (!length(idx)) next
    better <- score > out_scores[idx]
    out_scores[idx[better]] <- score
    out_reasons[idx[better]] <- alerts$reason_text[i]
  }
  out <- list(scores = out_scores, reasons = out_reasons)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

# Why: combine the official WI511 road overlay and the message-sign road
# signal into one per-road score that reflects both sources.
# What: returns list(scores, reasons, sources) keyed by road_id.
# How: projects roads to 5070, builds within-15km neighbourhoods, decays
# nearby official scores by exp(-d/6000), then merges sign signal taking
# the max per road and recording the dominant source.
# When: called by build_driving_roads_overlay when assembling the merged
# WI511 + modeled road risk.
# Impact: the 15km radius is the dominant lever - shrinking sharpens the
# overlay; growing softens it across regions.
compute_511_road_proximity_signal <- function(horizon_key = "live") {
  cache_name <- paste0("wi511-road-proximity-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  roads <- load_wi_roads()
  out_scores <- stats::setNames(rep(0, nrow(roads)), roads$road_id)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(roads)), roads$road_id)
  out_sources <- stats::setNames(rep(NA_character_, nrow(roads)), roads$road_id)
  official <- build_511_roads_overlay(horizon_key)
  sign_signal <- compute_511_message_sign_road_signal(horizon_key)
  if (nrow(roads) == 0 || (nrow(official) == 0 && !any((sign_signal$scores %||% 0) > 0))) {
    out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
    cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
    return(out)
  }
  roads_proj <- suppressWarnings(sf::st_transform(roads, 5070))
  if (nrow(official) > 0) {
    official <- repair_external_sf(official)
    official_proj <- suppressWarnings(sf::st_transform(official, 5070))
    hits <- suppressWarnings(sf::st_is_within_distance(roads_proj, official_proj, dist = 15000))
  } else {
    hits <- replicate(nrow(roads), integer(0), simplify = FALSE)
  }
  for (i in seq_along(hits)) {
    idx <- unique(as.integer(hits[[i]]))
    if (length(idx) == 0) next
    d <- safe_numeric(sf::st_distance(roads_proj[i, ], official_proj[idx, ]))
    if (length(d) == 0) next
    d[!is.finite(d)] <- 15000
    local_scores <- pmin(1, official$driving_total_risk[idx] * exp(-pmax(d, 0) / 6000))
    if (!any(is.finite(local_scores) & local_scores > 0)) next
    best <- which.max(local_scores)[1]
    out_scores[i] <- local_scores[best]
    out_reasons[i] <- paste0(as.character(official$driving_reason_text[idx[best]] %||% official$road_source[idx[best]] %||% "Official roadway disruption."), " Nearby official corridor conditions are influencing this road.")
    out_sources[i] <- as.character(official$road_source[idx[best]] %||% "511WI")
  }
  sign_scores <- sign_signal$scores %||% out_scores
  sign_reasons <- sign_signal$reasons %||% out_reasons
  sign_sources <- sign_signal$sources %||% out_sources
  if (length(sign_scores) > 0) {
    common_ids <- intersect(names(out_scores), names(sign_scores))
    better <- common_ids[sign_scores[common_ids] > out_scores[common_ids]]
    if (length(better) > 0) {
      out_scores[better] <- sign_scores[better]
      out_reasons[better] <- as.character(sign_reasons[better])
      out_sources[better] <- as.character(sign_sources[better])
    }
  }
  out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

# Why: produce the unified WI511 road-overlay sf by combining winter,
# travel-times, and events feeds with consistent styling.
# What: returns an sf with road_color/opacity/weight/popup_label etc., or
# empty_road_overlay_sf when no rows.
# How: rbinds standardize_road_overlay_sf(winter/travel/events), styles
# uniformly via risk_rgb_hex, caches under wi511-roads-overlay-<horizon>.
# When: called by build_driving_roads_overlay just before merging with
# modeled road risk.
# Impact: the source-of-truth for the WI511 overlay - any new feed needs
# to be added here and to standardize_road_overlay_sf's column list.
build_511_roads_overlay <- function(horizon_key = "live") {
  cache_name <- paste0("wi511-roads-overlay-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  # The three fetchers are independent I/O. mclapply forks workers (macOS /
  # Linux only) so the cold-cache wall time is one timeout instead of three.
  fetchers <- list(winter = fetch_511_winter_roads_live,
                   travel = fetch_511_travel_times_live,
                   events = fetch_511_events_live)
  use_parallel <- .Platform$OS.type != "windows"
  results <- if (use_parallel) {
    parallel::mclapply(fetchers, function(fn) safely(fn()),
                       mc.cores = 3L, mc.preschedule = FALSE)
  } else {
    lapply(fetchers, function(fn) safely(fn()))
  }
  winter <- results$winter
  travel <- results$travel
  events <- results$events
  out <- tryCatch(suppressWarnings(rbind(standardize_road_overlay_sf(winter), standardize_road_overlay_sf(travel), standardize_road_overlay_sf(events))), error = function(e) empty_road_overlay_sf())
  if (nrow(out) == 0) {
    ttl <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
    cache_put("derived", cache_name, out, ttl_seconds = ttl)
    return(out)
  }
  out <- repair_external_sf(out)
  if (nrow(out) == 0) {
    ttl <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
    cache_put("derived", cache_name, out, ttl_seconds = ttl)
    return(out)
  }
  if (!identical(horizon_key, "live")) {
    out$driving_total_risk <- apply_live_decay(out$driving_total_risk, horizon_key, half_life_hours = 12)
    out$driving_reason_text <- paste0(out$driving_reason_text, " Live roadway feed decayed for the selected forecast horizon.")
  }
  out$road_color <- risk_rgb_hex(out$driving_total_risk)
  out$road_opacity <- ifelse((out$driving_total_risk %||% 0) >= RISK_GREEN_MIN, 0.50, 0)
  out$road_weight <- ifelse(out$road_class == "511WI winter", 5.4, ifelse(out$road_class == "511WI event", 5.2, 4.8))
  out$driving_risk_label <- vapply(out$driving_total_risk, risk_label_from_score, character(1))
  ttl <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
  cache_put("derived", cache_name, out, ttl_seconds = ttl)
  out
}

# Why: top-level WI511 ZIP-level risk that fuses official road overlay,
# message signs, and prose alerts into one (score, reason) pair per ZIP.
# What: returns list(scores, reasons) keyed by zipcode; reasons reflect the
# winning source per ZIP.
# How: starts from official-overlay proximity (within 22km, 9km decay),
# overlays sign signal where higher, overlays alert signal where higher,
# caches.
# When: called per horizon by the WI511 transport pipeline.
# Impact: this is the per-ZIP "transport risk" surface used in driving
# scoring; ordering of overlays here decides which source wins ties.
compute_511_zip_transport_risk <- function(horizon_key = "live") {
  key <- paste0("wi511-zip-transport-", horizon_key)
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  official <- build_511_roads_overlay(horizon_key)
  if (nrow(official) > 0) {
    official <- repair_external_sf(official)
    zip_pts_proj <- wi_zip_points_proj
    official_proj <- suppressWarnings(sf::st_transform(official, 5070))
    poly_hits <- safe_st_intersects(wi_zctas, official)
    prox_hits <- suppressWarnings(sf::st_is_within_distance(zip_pts_proj, official_proj, dist = 22000))
    for (i in seq_along(out_scores)) {
      idx <- unique(c(as.integer(poly_hits[[i]]), as.integer(prox_hits[[i]])))
      idx <- idx[is.finite(idx)]
      if (length(idx) == 0) next
      vals <- safe_numeric(official$driving_total_risk[idx])
      vals[!is.finite(vals)] <- 0
      if (!any(vals > 0)) next
      d <- safe_numeric(sf::st_distance(zip_pts_proj[i, ], official_proj[idx, ]))
      if (length(d) == 0) d <- rep(22000, length(idx))
      d[!is.finite(d)] <- 22000
      intersect_idx <- as.integer(poly_hits[[i]])
      if (length(intersect_idx) > 0) {
        pos <- match(intersect_idx, idx, nomatch = 0)
        pos <- pos[pos > 0]
        if (length(pos) > 0) d[pos] <- 0
      }
      local_scores <- pmin(1, vals * exp(-pmax(d, 0) / 9000))
      best_local <- which.max(local_scores)[1]
      out_scores[i] <- local_scores[best_local]
      out_reasons[i] <- as.character(official$driving_reason_text[idx[best_local]] %||% official$road_source[idx[best_local]] %||% NA_character_)
    }
  }
  sign_signal <- compute_511_message_sign_zip_signal(horizon_key)
  sign_scores <- unname(sign_signal$scores[wi_zctas$zipcode])
  sign_reasons <- unname(sign_signal$reasons[wi_zctas$zipcode])
  sign_scores[!is.finite(sign_scores)] <- 0
  use_sign <- sign_scores > out_scores
  out_scores[use_sign] <- sign_scores[use_sign]
  out_reasons[use_sign] <- sign_reasons[use_sign]

  alert_signal <- compute_511_alert_zip_signal(horizon_key)
  alert_scores <- unname(alert_signal$scores[wi_zctas$zipcode])
  alert_reasons <- unname(alert_signal$reasons[wi_zctas$zipcode])
  alert_scores[!is.finite(alert_scores)] <- 0
  use_alert <- alert_scores > out_scores
  out_scores[use_alert] <- alert_scores[use_alert]
  out_reasons[use_alert] <- alert_reasons[use_alert]
  out <- list(scores = out_scores, reasons = out_reasons)
  cache_put("derived", key, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}
