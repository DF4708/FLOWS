# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/uv_seismic.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: per-ZIP UV scoring is too many EPA UV API calls; we score per
# latitude band representative ZIP and broadcast.
# What: returns a named numeric vector indexed by lat_band character with
# a 0..1 UV risk per band, cached for 6 hours.
# How: for each band's rep_zip, fetch EPA UV daily JSON, extract value and
# alert flag, blend into one band score using a noisy-OR (0.7*value, 0.3*alert).
# When: called by the UV/heat hazard pipeline; results joined by lat_band.
# Impact: a zero-score band leaves the UV component out of every ZIP in
# that band - rate-limit failures from EPA collapse the layer silently.
fetch_uv_band_scores <- function() {
  cached <- cache_get("derived", "uv-band-scores")
  if (!is.null(cached)) return(cached)
  fetch_one_band <- function(i) {
    zip_code <- as.character(band_reps$rep_zip[i] %||% "")
    if (!nzchar(zip_code)) return(0)
    url <- sprintf(EPA_UV_DAILY_URL, zip_code)
    payload <- safely(http_json_simple(url))
    uv <- parse_uv_daily_payload(payload)
    uv_score <- score_uv_value(uv$uv_value)
    uv_alert_score <- if (isTRUE(uv$uv_alert)) 1 else 0
    pmin(1, 1 - (1 - 0.70 * uv_score) * (1 - 0.30 * uv_alert_score))
  }
  # Parallelise the 10 per-band EPA UV API calls. Each is independent and
  # dominated by network latency, so mclapply compresses the wall time from
  # ~10 sequential RTTs to roughly one. Windows falls through to lapply.
  band_seq <- seq_len(nrow(band_reps))
  use_parallel <- .Platform$OS.type != "windows"
  values <- if (use_parallel && length(band_seq) > 1) {
    parallel::mclapply(band_seq, fetch_one_band,
                       mc.cores = max(1L, min(length(band_seq), 6L)),
                       mc.preschedule = FALSE)
  } else {
    lapply(band_seq, fetch_one_band)
  }
  out <- vapply(values, function(v) {
    v <- suppressWarnings(as.numeric(v))
    if (length(v) != 1L || !is.finite(v)) 0 else v
  }, numeric(1))
  names(out) <- as.character(band_reps$lat_band)
  cache_put("derived", "uv-band-scores", out, ttl_seconds = 6 * 3600)
  out
}

# Why: a downstream consumer needs the assembled output in a single call
# rather than calling the underlying primitives separately.
# What: Builds the USGS earthquake API URL covering wi_bounds (+1deg
# buffer) for the past days_back days at >= min_magnitude.
# How: cache lookup + put + named vector build.
# When: called by the layer's top-level builder when assembling the
# user-visible output.
# Impact: any new column or row source needs to be added here AND in the
# layer's standardise_* schema; mismatched schemas show up as silent column
# drops downstream.
build_usgs_query_url <- function(days_back = USGS_QUAKE_DAYS, min_magnitude = USGS_QUAKE_MIN_MAG) {
  start_time <- format(Sys.time() - days_back * 24 * 3600, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  sprintf(
    paste0(
      "https://earthquake.usgs.gov/fdsnws/event/1/query.geojson?format=geojson",
      "&starttime=%s&minmagnitude=%.1f",
      "&minlatitude=%.4f&maxlatitude=%.4f&minlongitude=%.4f&maxlongitude=%.4f"
    ),
    utils::URLencode(start_time, reserved = TRUE),
    min_magnitude,
    wi_bounds$south - 1,
    wi_bounds$north + 1,
    wi_bounds$west - 1,
    wi_bounds$east + 1
  )
}

# Why: convert recent USGS earthquakes into per-ZIP scores attenuated by
# distance and event age.
# What: returns list(scores, labels) keyed by ZCTA - 0..1 score, labels
# carry the event title for popup text.
# How: for each event, computes piecewise_score(mag, 2.5, 4.0, 5.5),
# multiplies by exp(-km/160) and exp(-age_hours/48), keeps the per-ZIP max.
# When: called by the seismic scoring pipeline; cached for 30 minutes.
# Impact: distance and age constants shape the radius of influence; a near
# but old quake can fade below a far but recent one.
fetch_usgs_seismic_scores <- function() {
  cached <- cache_get("derived", "usgs-seismic-scores")
  if (!is.null(cached)) return(cached)
  scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  labels <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  payload <- safely(http_json(build_usgs_query_url()))
  features <- payload$features %||% list()
  if (length(features) == 0) {
    out <- list(scores = scores, labels = labels)
    cache_put("derived", "usgs-seismic-scores", out, ttl_seconds = 30 * 60)
    return(out)
  }
  zip_pts_proj <- wi_zip_points_proj
  for (feat in features) {
    props <- feat$properties %||% list()
    coords <- feat$geometry$coordinates %||% list()
    if (length(coords) < 2) next
    lon <- safe_numeric(coords[[1]])
    lat <- safe_numeric(coords[[2]])
    mag <- safe_numeric(props$mag %||% NA_real_)
    if (!is.finite(lon) || !is.finite(lat) || !is.finite(mag)) next
    event_sf <- sf::st_as_sf(data.frame(id = 1L, lon = lon, lat = lat), coords = c("lon", "lat"), crs = 4326)
    event_proj <- suppressWarnings(sf::st_transform(event_sf, 5070))
    dkm <- as.numeric(sf::st_distance(zip_pts_proj, event_proj)) / 1000
    dkm[!is.finite(dkm)] <- Inf
    mag_score <- piecewise_score(mag, 2.5, 4.0, 5.5)
    event_time <- suppressWarnings(as.POSIXct((props$time %||% NA_real_) / 1000, origin = "1970-01-01", tz = "UTC"))
    age_hours <- if (is.finite(as.numeric(event_time))) pmax(0, as.numeric(difftime(Sys.time(), event_time, units = "hours"))) else 168
    age_decay <- exp(-age_hours / 48)
    event_scores <- pmin(1, mag_score * exp(-dkm / 160) * age_decay)
    better <- event_scores > scores
    if (any(better)) {
      scores[better] <- event_scores[better]
      labels[better] <- as.character(props$title %||% "Recent earthquake")
    }
  }
  out <- list(scores = scores, labels = labels)
  cache_put("derived", "usgs-seismic-scores", out, ttl_seconds = 30 * 60)
  out
}
