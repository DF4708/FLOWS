# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_events.R - scorer + fetcher for the 511WI events feed
# (crashes, closures, hazmat, roadwork). The structured
# is_full_closure flag is the authoritative full-closure signal.


# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps WI511 incident text + severity + closure flag to a 0..1 SAFETY
# risk. The structured is_full_closure flag (from the API) is the
# authoritative full-closure signal; bare "closed|closure" is too loose
# (matches "flex lane closed", "ramp closed for metering", etc.) so we
# require explicit road / highway / interstate / "all lanes" context in the
# freeform text. Throughput-management rows (flex / HOV / managed / express
# / ramp metering / toll plaza) drop to 0 unless they also carry a real
# hazard keyword.
# How: regex match.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_511_event_risk <- function(description = "", event_type = "", event_subtype = "", severity = "", lanes_affected = "", is_full_closure = FALSE) {
  text <- tolower(trimws(paste(description, event_type, event_subtype, severity, lanes_affected, collapse = " | ")))
  if (is_operational_only_511_text(text)) return(0)
  if (isTRUE(is_full_closure) ||
      grepl("all lanes closed|full closure|road closed|highway closed|interstate closed|impassable|emergency closure",
            text, perl = TRUE)) return(1.00)
  if (grepl("jackknife|hazmat|fire|washout|bridge collapse|sinkhole|flood", text)) return(0.95)
  if (grepl("tornado|damaging wind|microburst|large hail|dust storm|haboob|severe thunderstorm warning", text, perl = TRUE)) return(0.92)
  if (grepl("accident|crash|incident|overturned|disabled vehicle", text)) return(0.75)
  if (grepl("roadwork|construction|maintenance", text)) return(0.45)
  if (grepl("shoulder closed|reduced to one lane", text)) return(0.40)
  sev <- tolower(trimws(safe_string(severity)))
  if (sev %in% c("major", "high", "severe")) return(0.80)
  if (sev %in% c("medium", "moderate")) return(0.55)
  if (sev %in% c("minor", "low")) return(0.30)
  if (!nzchar(trimws(text))) return(0)
  0
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
  total_seen <- 0L
  dropped_low_risk <- 0L
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      total_seen <- total_seen + 1L
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
      if (!is.finite(score_live) || score_live < WI511_MIN_RISK_THRESHOLD) {
        dropped_low_risk <- dropped_low_risk + 1L
        next
      }
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
  message(sprintf("[FLOWS-DEBUG] 511 events: kept %d / %d (dropped %d below threshold %.2f).",
                  length(rows), total_seen, dropped_low_risk, WI511_MIN_RISK_THRESHOLD))
  if (length(rows) == 0) {
    out <- empty_road_overlay_sf()
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  out <- sf::st_sf(flows_bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

