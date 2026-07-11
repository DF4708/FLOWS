# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_signs.R - scorer, fetcher, and per-ZIP / per-road signals
# for the WI511 dynamic message-sign feed. Operational-only signs
# (lane management, ramp metering, etc.) drop to 0 via
# is_operational_only_511_text.


# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a dynamic message-sign text to a 0..1 SAFETY risk. Operational
# text (flex / HOV / managed / express / ramp meter / toll plaza / special
# event traffic) drops to 0 unless mixed with a real safety keyword. Bare
# "closed" tightened to require road / highway / interstate / "all lanes"
# context — used to fire on "FLEX LANE CLOSED TO TRAFFIC".
# How: regex match + cache lookup + put + sf geometry op.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_511_message_sign_risk <- function(message_text = "") {
  txt <- tolower(trimws(safe_string(message_text)))
  if (!nzchar(txt) || identical(txt, "no_message")) return(0)
  if (is_operational_only_511_text(txt)) return(0)
  score <- 0.18
  if (grepl("flood|washout|bridge collapse|sinkhole|hazmat|fire|jackknife", txt)) score <- max(score, 0.95)
  if (grepl("tornado|damaging wind|microburst|large hail|dust storm|haboob|severe thunderstorm warning", txt, perl = TRUE)) score <- max(score, 0.92)
  if (grepl("road closed|highway closed|interstate closed|all lanes closed|emergency closure|impassable|do not use", txt, perl = TRUE)) score <- max(score, 0.90)
  if (grepl("crash|incident|disabled vehicle|overturned", txt)) score <- max(score, 0.60)
  if (grepl("slippery|ic[ey]|snow|winter|blowing snow|reduced visibility|fog|signal out|signal dark", txt, perl = TRUE)) score <- max(score, 0.58)
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
  total_seen <- 0L
  dropped_low_risk <- 0L
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      total_seen <- total_seen + 1L
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
      if (!is.finite(score_live) || score_live < WI511_MIN_RISK_THRESHOLD) {
        dropped_low_risk <- dropped_low_risk + 1L
        next
      }
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
  message(sprintf("[FLOWS-DEBUG] 511 message signs: kept %d / %d (dropped %d below threshold %.2f).",
                  length(rows), total_seen, dropped_low_risk, WI511_MIN_RISK_THRESHOLD))
  out <- if (length(rows) == 0) {
    sf::st_sf(sign_id = character(0), road_name = character(0), county = character(0), direction = character(0), message_text = character(0), sign_score = numeric(0), sign_reason_text = character(0), geometry = sf::st_sfc(crs = 4326))
  } else {
    sf::st_sf(flows_bind_rows(rows), geometry = sf::st_sfc(geoms, crs = 4326))
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
  # Bulk distance matrix replaces per-ZIP st_distance loops. With the
  # noise filter trimming signs to ~10 rows, the matrix is ~861 * 10 =
  # ~8.6 KB. One sf call vs 861 — cuts the loop from minutes to ~1 s.
  d_full_signs <- if (any(lengths(hits) > 0)) {
    tryCatch({
      m <- suppressWarnings(sf::st_distance(zip_pts_proj, signs_proj))
      m <- matrix(as.numeric(m), nrow = nrow(zip_pts_proj))
      m[!is.finite(m)] <- 18000
      m
    }, error = function(e) NULL)
  } else NULL
  sign_score_vec <- safe_numeric(signs$sign_score %||% 0)
  sign_reason_vec <- as.character(signs$sign_reason_text %||% rep("", nrow(signs)))
  for (i in seq_along(hits)) {
    idx <- unique(as.integer(hits[[i]]))
    if (length(idx) == 0) next
    d <- if (!is.null(d_full_signs)) d_full_signs[i, idx] else {
      v <- safe_numeric(sf::st_distance(zip_pts_proj[i, ], signs_proj[idx, ]))
      v[!is.finite(v)] <- 18000
      v
    }
    road_hits <- vapply(idx, function(j) wi_zctas$zipcode[i] %in% (extract_roadway_zipcodes_from_text(signs$road_name[j], max_tokens = 2L) %||% character(0)), logical(1))
    road_boost <- ifelse(road_hits, 1.18, 1.00)
    local_scores <- pmin(1, sign_score_vec[idx] * exp(-pmax(d, 0) / 7000) * road_boost)
    if (!any(is.finite(local_scores) & local_scores > 0)) next
    best <- which.max(local_scores)[1]
    out_scores[i] <- local_scores[best]
    out_reasons[i] <- paste0(sign_reason_vec[idx[best]], " Nearby dynamic-message-sign conditions are influencing this ZIP.")
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
compute_511_message_sign_road_signal <- function(horizon_key = "live", progress = NULL) {
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
  roads_proj <- load_wi_roads_proj()
  if (is.null(roads_proj)) roads_proj <- suppressWarnings(sf::st_transform(roads, 5070))
  signs_proj <- suppressWarnings(sf::st_transform(signs, 5070))
  hits <- suppressWarnings(sf::st_is_within_distance(roads_proj, signs_proj, dist = 12000))
  road_norm <- normalize_route_text(roads$road_name)
  sign_norm <- normalize_route_text(signs$road_name)
  band_info <- tryCatch(load_wi_roads_lat_band_groups(), error = function(e) NULL)
  band_groups <- if (!is.null(band_info)) band_info$groups else list(seq_len(nrow(roads)))
  total_bands <- length(band_groups)
  # Bulk distance matrix replaces per-OSM-road st_distance calls; with the
  # noise filter trimming signs to ~10 rows, the matrix is ~84k * 10 = ~6.7
  # MB. One sf call vs ~84k.
  d_full_signs <- if (any(lengths(hits) > 0)) {
    tryCatch({
      m <- suppressWarnings(sf::st_distance(roads_proj, signs_proj))
      m <- matrix(as.numeric(m), nrow = nrow(roads_proj))
      m[!is.finite(m)] <- 12000
      m
    }, error = function(e) NULL)
  } else NULL
  sign_score_vec <- safe_numeric(signs$sign_score %||% 0)
  sign_reason_vec <- as.character(signs$sign_reason_text %||% rep("", nrow(signs)))
  for (band_idx in seq_along(band_groups)) {
    band_rows <- band_groups[[band_idx]]
    for (i in band_rows) {
      idx <- unique(as.integer(hits[[i]]))
      if (length(idx) == 0) next
      d <- if (!is.null(d_full_signs)) d_full_signs[i, idx] else {
        v <- safe_numeric(sf::st_distance(roads_proj[i, ], signs_proj[idx, ]))
        v[!is.finite(v)] <- 12000
        v
      }
      name_boost <- ifelse(sign_norm[idx] == road_norm[i] & nzchar(road_norm[i]), 1.25, 1.00)
      local_scores <- pmin(1, sign_score_vec[idx] * exp(-pmax(d, 0) / 4500) * name_boost)
      if (!any(is.finite(local_scores) & local_scores > 0)) next
      best <- which.max(local_scores)[1]
      out_scores[i] <- local_scores[best]
      out_reasons[i] <- paste0(sign_reason_vec[idx[best]], " Nearby dynamic-message-sign conditions are influencing this road.")
      out_sources[i] <- "511WI message signs"
    }
    notify_progress(progress, value = NULL,
      detail = sprintf("Computing 511 message-sign road signal, band %d of %d.",
                       band_idx, total_bands))
  }
  out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

