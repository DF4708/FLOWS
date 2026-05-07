# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_winter.R - scorer + fetcher for the 511WI winter-roads feed.
# Winter road status (closed/ice/snow/etc.) is inherently safety-
# relevant so the scoring is straightforward keyword priority.

# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/wi511.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a 511WI winter road status string ("ice covered", "closed",
# "wet", etc.) to a fixed 0..1 risk score by keyword priority.
# How: regex match + cache lookup + put.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
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
  total_seen <- 0L
  dropped_low_risk <- 0L
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      total_seen <- total_seen + 1L
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
      # Noise floor: drop "normal/clear/good" segments and other below-threshold
      # rows so they never enter the downstream snap / per-ZIP / color pipeline.
      if (!is.finite(score_live) || score_live < WI511_MIN_RISK_THRESHOLD) {
        dropped_low_risk <- dropped_low_risk + 1L
        next
      }
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
  message(sprintf("[FLOWS-DEBUG] 511 winter roads: kept %d / %d (dropped %d below threshold %.2f).",
                  length(rows), total_seen, dropped_low_risk, WI511_MIN_RISK_THRESHOLD))
  if (length(rows) == 0) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  out <- sf::st_sf(dplyr::bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

