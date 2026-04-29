# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/airnow.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Maps a raw AQI value to a 0..1 risk by piecewise-scoring (aqi - 50) with thresholds (25, 75, 150) - AQI <= 50 is "good" -> 0.
score_airnow_aqi <- function(aqi_value) {
  aqi_value <- safe_numeric(aqi_value)
  if (!is.finite(aqi_value) || aqi_value <= 50) return(0)
  piecewise_score(aqi_value - 50, 25, 75, 150)
}

# Lowercases and strips non-alphanumeric characters from x to build a stable join key for AirNow reporting-area names.
sanitize_name_key <- function(x) {
  tolower(gsub("[^a-z0-9]+", "", safe_string(x), perl = TRUE))
}

# Returns the first column name in dat whose sanitized form matches one of the candidate names, else NA_character_.
find_matching_column <- function(dat, candidates = character(0)) {
  if (is.null(dat) || !is.data.frame(dat) || ncol(dat) == 0) return(NA_character_)
  keys <- sanitize_name_key(names(dat))
  cand_keys <- sanitize_name_key(candidates)
  idx <- match(cand_keys, keys)
  idx <- idx[is.finite(idx)]
  if (length(idx) == 0) return(NA_character_)
  names(dat)[idx[1]]
}

# Parses an AirNow date string trying "m/d/y" then "m/d/Y", returning NA Date for empty or unparseable input.
parse_airnow_date <- function(x) {
  x <- trimws(safe_string(x))
  if (!nzchar(x)) return(as.Date(NA))
  parsed <- suppressWarnings(as.Date(x, format = "%m/%d/%y"))
  if (is.na(parsed)) parsed <- suppressWarnings(as.Date(x, format = "%m/%d/%Y"))
  parsed
}

# Returns today's date in America/Chicago (Wisconsin's local timezone), used as the anchor for forecast horizon offsets.
airnow_current_central_date <- function() {
  as.Date(format(Sys.time(), tz = "America/Chicago", usetz = FALSE))
}

# Maps a horizon key ("live"/"24h"/"48h"/"72h") to the matching central-time forecast date (today + 0/1/2/3).
airnow_target_date_from_horizon <- function(horizon_key = "live") {
  offset <- switch(horizon_key %||% "live", live = 0L, `24h` = 1L, `48h` = 2L, `72h` = 3L, 0L)
  airnow_current_central_date() + offset
}

# Why: forecast feeds sometimes give a category label without a numeric AQI,
# so we approximate a representative AQI for scoring.
# What: returns a numeric (e.g., 350 for "Hazardous", 25 for "Good") or
# NA_real_ if no keyword matches.
# How: lowercases the input and tests against the official EPA AQI category
# names in priority order.
# When: called by score_airnow_row when aqi_value is missing.
# Impact: the chosen midpoints determine the score's intensity; matching is
# textual and thus brittle to label changes from EPA.
airnow_category_representative_aqi <- function(category_text = "") {
  cat <- tolower(trimws(safe_string(category_text)))
  if (!nzchar(cat)) return(NA_real_)
  if (grepl("hazardous", cat, fixed = TRUE)) return(350)
  if (grepl("very unhealthy", cat, fixed = TRUE)) return(250)
  if (grepl("unhealthy for sensitive", cat, fixed = TRUE)) return(125)
  if (grepl("unhealthy", cat, fixed = TRUE)) return(175)
  if (grepl("moderate", cat, fixed = TRUE)) return(75)
  if (grepl("good", cat, fixed = TRUE)) return(25)
  NA_real_
}

# Best-effort row score: prefers numeric aqi_value, falls back to airnow_category_representative_aqi(category_text), else 0.
score_airnow_row <- function(aqi_value = NA_real_, category_text = "") {
  aqi_value <- safe_numeric(aqi_value)
  if (is.finite(aqi_value)) return(score_airnow_aqi(aqi_value))
  fallback_aqi <- airnow_category_representative_aqi(category_text)
  if (is.finite(fallback_aqi)) return(score_airnow_aqi(fallback_aqi))
  0
}

# Why: the AirNow reportingarea pipe-delimited file has no header, so we
# impose the canonical schema by hand and clean each column.
# What: returns a data.frame with the 17 documented columns plus
# valid_date_parsed and a join key, or NULL on parse failure.
# How: read.delim with sep="|", pads short rows with NA, applies
# trim/upper/numeric coercions, derives valid_date_parsed and key via
# sanitize_name_key + state_code.
# When: called once per cache cycle by fetch_airnow_reportingarea_tables.
# Impact: column-count drift would silently re-align fields and corrupt the
# entire forecast; the explicit schema is the safety net.
parse_reportingarea_text <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NULL)
  cols <- c(
    "issue_date", "valid_date", "valid_time", "time_zone", "record_sequence", "data_type", "primary_flag",
    "reporting_area", "state_code", "latitude", "longitude", "pollutant", "aqi_value", "aqi_category",
    "action_day", "discussion", "forecast_source"
  )
  dat <- safely(
    utils::read.delim(text = txt, header = FALSE, sep = "|", stringsAsFactors = FALSE, quote = "", fill = TRUE, comment.char = "")
  )
  if (is.null(dat) || ncol(dat) == 0) return(NULL)
  if (ncol(dat) < length(cols)) {
    for (i in seq.int(ncol(dat) + 1L, length(cols))) dat[[i]] <- NA_character_
  }
  dat <- dat[, seq_along(cols), drop = FALSE]
  names(dat) <- cols
  dat$state_code <- toupper(trimws(safe_string(dat$state_code)))
  dat$reporting_area <- trimws(safe_string(dat$reporting_area))
  dat$pollutant <- trimws(safe_string(dat$pollutant))
  dat$data_type <- toupper(trimws(safe_string(dat$data_type)))
  dat$primary_flag <- toupper(trimws(safe_string(dat$primary_flag)))
  dat$aqi_value <- safe_numeric(dat$aqi_value)
  dat$latitude <- safe_numeric(dat$latitude)
  dat$longitude <- safe_numeric(dat$longitude)
  dat$valid_date_parsed <- as.Date(vapply(dat$valid_date, function(v) format(parse_airnow_date(v), "%Y-%m-%d"), character(1)), format = "%Y-%m-%d")
  dat$key <- paste0(sanitize_name_key(dat$reporting_area), "::", dat$state_code)
  dat
}

# Why: AirNow's "city zipcodes" CSV publishes header names that vary between
# refreshes, so we tolerate column synonyms.
# What: returns a clean data.frame(zipcode, state_code, reporting_area,
# latitude, longitude, key) keyed for joining onto reportingarea, or NULL.
# How: find_matching_column for each logical field, zero-pads zip to 5
# digits, drops rows with empty zip/area, builds the same key as
# parse_reportingarea_text.
# When: called by fetch_airnow_reportingarea_tables alongside the reporting
# area parse.
# Impact: missing required columns (zip/state/area) produces NULL and the
# forecast pipeline falls back to nearest-area-only scoring.
parse_cityzipcodes_csv <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NULL)
  dat <- safely(utils::read.csv(text = txt, stringsAsFactors = FALSE))
  if (is.null(dat) || nrow(dat) == 0) return(NULL)
  zip_col <- find_matching_column(dat, c("zipcode", "zip_code", "zip", "zipcd", "postalcode"))
  state_col <- find_matching_column(dat, c("state", "statecode", "stateabbreviation"))
  area_col <- find_matching_column(dat, c("reportingarea", "reporting_area", "reportingareaname", "areaname", "city", "cityname", "reportarea"))
  lat_col <- find_matching_column(dat, c("latitude", "lat", "ziplatitude"))
  lon_col <- find_matching_column(dat, c("longitude", "lon", "long", "ziplongitude"))
  if (is.na(zip_col) || is.na(state_col) || is.na(area_col)) return(NULL)
  out <- data.frame(
    zipcode = sprintf("%05s", gsub("[^0-9]", "", safe_string(dat[[zip_col]]))),
    state_code = toupper(trimws(safe_string(dat[[state_col]]))),
    reporting_area = trimws(safe_string(dat[[area_col]])),
    stringsAsFactors = FALSE
  )
  if (!is.na(lat_col)) out$latitude <- safe_numeric(dat[[lat_col]]) else out$latitude <- NA_real_
  if (!is.na(lon_col)) out$longitude <- safe_numeric(dat[[lon_col]]) else out$longitude <- NA_real_
  out <- out[nzchar(out$zipcode) & nchar(out$zipcode) == 5 & nzchar(out$reporting_area), , drop = FALSE]
  out$key <- paste0(sanitize_name_key(out$reporting_area), "::", out$state_code)
  unique(out)
}

# Fetches both AirNow forecast tables (reporting + city-zip) once per hour and caches the parsed pair under "derived".
fetch_airnow_reportingarea_tables <- function() {
  cached <- cache_get("derived", "airnow-reportingarea-tables")
  if (!is.null(cached)) return(cached)

  reporting_txt <- safely(http_text(AIRNOW_REPORTINGAREA_URL, user_agent = NOAA_USER_AGENT))
  cityzip_txt <- safely(http_text(AIRNOW_CITYZIPCODES_URL, user_agent = NOAA_USER_AGENT))
  tables <- list(
    reporting = parse_reportingarea_text(reporting_txt),
    cityzip = parse_cityzipcodes_csv(cityzip_txt)
  )
  cache_put("derived", "airnow-reportingarea-tables", tables, ttl_seconds = 3600)
  tables
}

# Why: convert AirNow forecast text into a per-ZIP risk score for the chosen
# horizon, falling back gracefully when a horizon has no published forecast.
# What: returns a named numeric vector (one entry per ZCTA, names are
# zipcodes) with attribute has_forecast indicating whether the result is
# real or all-zero placeholder.
# How: filters reporting area to TARGET_STATE + matching valid_date,
# aggregates max row score per area, joins via cityzip key, and fills in
# remaining ZIPs by st_nearest_feature on area centroids.
# When: invoked by fetch_airnow_scores when horizon != "live".
# Impact: a missing forecast tier sets has_forecast=FALSE so fetch_airnow_scores
# falls back to live + decay; an aggregation bug here biases the entire
# air-quality layer for the day.
compute_airnow_forecast_zip_scores <- function(horizon_key = "24h") {
  cache_name <- paste0("airnow-forecast-scores-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)

  out <- stats::setNames(rep(NA_real_, nrow(wi_zctas)), wi_zctas$zipcode)
  attr(out, "has_forecast") <- FALSE
  tables <- fetch_airnow_reportingarea_tables()
  reporting <- tables$reporting
  cityzip <- tables$cityzip
  if (is.null(reporting) || nrow(reporting) == 0) {
    cache_put("derived", cache_name, out, ttl_seconds = 1800)
    return(out)
  }

  target_date <- airnow_target_date_from_horizon(horizon_key)
  reporting <- reporting[
    reporting$state_code == TARGET_STATE &
      reporting$data_type == "F" &
      !is.na(reporting$valid_date_parsed) &
      reporting$valid_date_parsed == target_date,
    , drop = FALSE
  ]
  if (!is.null(cityzip) && nrow(cityzip) > 0) {
    cityzip <- cityzip[cityzip$state_code == TARGET_STATE, , drop = FALSE]
  }
  if (nrow(reporting) == 0) {
    cache_put("derived", cache_name, out, ttl_seconds = 1800)
    return(out)
  }

  attr(out, "has_forecast") <- TRUE
  reporting$row_score <- mapply(score_airnow_row, reporting$aqi_value, reporting$aqi_category)
  reporting <- reporting[is.finite(reporting$row_score), , drop = FALSE]
  if (nrow(reporting) == 0) {
    cache_put("derived", cache_name, out, ttl_seconds = 1800)
    return(out)
  }

  area_max <- stats::aggregate(
    reporting[, c("row_score", "latitude", "longitude")],
    by = list(key = reporting$key, reporting_area = reporting$reporting_area, state_code = reporting$state_code),
    FUN = function(v) {
      vals <- safe_numeric(v)
      vals <- vals[is.finite(vals)]
      if (length(vals) == 0) return(NA_real_)
      max(vals, na.rm = TRUE)
    }
  )
  names(area_max)[names(area_max) == "row_score"] <- "aqi_score"

  if (!is.null(cityzip) && nrow(cityzip) > 0) {
    direct <- merge(cityzip[, c("zipcode", "key")], area_max[, c("key", "aqi_score")], by = "key", all.x = FALSE, all.y = FALSE)
    if (nrow(direct) > 0) {
      zip_scores <- stats::aggregate(direct$aqi_score, by = list(zipcode = direct$zipcode), FUN = max)
      out[zip_scores$zipcode] <- zip_scores$x
    }
  }

  missing_zips <- names(out)[!is.finite(out)]
  if (length(missing_zips) > 0) {
    valid_area_pts <- area_max[is.finite(area_max$latitude) & is.finite(area_max$longitude) & is.finite(area_max$aqi_score), , drop = FALSE]
    if (nrow(valid_area_pts) > 0) {
      area_sf <- sf::st_as_sf(valid_area_pts, coords = c("longitude", "latitude"), crs = 4326)
      zip_idx <- match(missing_zips, wi_zctas$zipcode)
      keep <- is.finite(zip_idx)
      valid_missing_zips <- missing_zips[keep]
      if (length(valid_missing_zips) > 0) {
        zip_pts <- wi_zip_points[zip_idx[keep], ]
        nearest_idx <- sf::st_nearest_feature(zip_pts, area_sf)
        out[valid_missing_zips] <- area_sf$aqi_score[nearest_idx]
      }
    }
  }

  out[!is.finite(out)] <- 0
  attr(out, "has_forecast") <- TRUE
  cache_put("derived", cache_name, out, ttl_seconds = 1800)
  out
}

# Why: callers want one entry point for AirNow regardless of horizon, with
# automatic fallback when no forecast is published.
# What: returns a named numeric vector of per-ZIP scores; for "live" returns
# fetch_airnow_live_scores, otherwise the forecast (or decayed live).
# How: dispatches on horizon_key; if has_forecast attribute is FALSE,
# decays the live scores via apply_live_decay (18-hour half life).
# When: top-level call from the air-quality scoring pipeline.
# Impact: this is the only place horizon-aware policy for AirNow lives - any
# change here affects every horizon view of the AQ layer.
fetch_airnow_scores <- function(horizon_key = "live") {
  if (identical(horizon_key, "live")) return(fetch_airnow_live_scores())
  forecast_scores <- compute_airnow_forecast_zip_scores(horizon_key)
  if (!isTRUE(attr(forecast_scores, "has_forecast"))) {
    live_scores <- fetch_airnow_live_scores()
    return(apply_live_decay(live_scores, horizon_key, half_life_hours = 18))
  }
  forecast_scores[!is.finite(forecast_scores)] <- 0
  forecast_scores
}

# Builds the list of HourlyAQObs_*.dat URLs for the past lookback_hours so the live fetcher can try the freshest first.
build_airnow_hourly_urls <- function(now_utc = Sys.time(), lookback_hours = AIRNOW_OBS_LOOKBACK_HOURS) {
  base_time <- as.POSIXct(format(now_utc, "%Y-%m-%d %H:00:00", tz = "UTC"), tz = "UTC")
  times <- base_time - seq(1, lookback_hours, by = 1) * 3600
  unique(vapply(
    times,
    function(ts) sprintf(
      "%s/%s/%s/HourlyAQObs_%s.dat",
      AIRNOW_FILES_BASE_URL,
      format(ts, "%Y", tz = "UTC"),
      format(ts, "%Y%m%d", tz = "UTC"),
      format(ts, "%Y%m%d%H", tz = "UTC")
    ),
    character(1)
  ))
}

# Reads AirNow HourlyAQObs CSV text into a data.frame, returning NULL on parse error or empty input.
parse_airnow_hourly_text <- function(txt) {
  if (is.null(txt) || !nzchar(txt)) return(NULL)
  safely(
    utils::read.csv(text = txt, stringsAsFactors = FALSE, strip.white = TRUE)
  )
}

# Why: live AirNow per-ZIP risk should reflect the freshest hourly file
# available, falling through older hours if the most recent is not yet posted.
# What: returns a named numeric vector (zipcode -> 0..1) cached for 30 min
# in both memory and on-disk snapshot.
# How: iterates build_airnow_hourly_urls newest-first, parses CSV, filters
# to TARGET_STATE rows with at least one AQI column, takes per-station max
# AQI, scores it, and assigns each ZCTA the score of its nearest station.
# When: called by fetch_airnow_scores for the "live" horizon.
# Impact: when no station file is reachable the layer collapses to all 0;
# nearest-feature assignment can be misleading at the edges of WI.
fetch_airnow_live_scores <- function() {
  cached <- cache_get("derived", "airnow-live-scores")
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file("derived_airnow_live_scores")
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 3600)
  if (!is.null(persisted)) {
    cache_put("derived", "airnow-live-scores", persisted, ttl_seconds = 1800)
    return(persisted)
  }
  out <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  wi_air <- NULL
  for (url in build_airnow_hourly_urls()) {
    txt <- safely(http_text(url, user_agent = NOAA_USER_AGENT))
    dat <- parse_airnow_hourly_text(txt)
    if (is.null(dat) || nrow(dat) == 0) next
    state_col <- names(dat)[tolower(names(dat)) %in% c("statename", "stateabbreviation", "state")]
    lat_col <- names(dat)[tolower(names(dat)) == "latitude"]
    lon_col <- names(dat)[tolower(names(dat)) == "longitude"]
    if (length(state_col) == 0 || length(lat_col) == 0 || length(lon_col) == 0) next
    dat <- dat[toupper(as.character(dat[[state_col[1]]])) == TARGET_STATE, , drop = FALSE]
    if (nrow(dat) == 0) next
    aqi_cols <- intersect(c("OZONE_AQI", "PM10_AQI", "PM25_AQI", "NO2_AQI"), names(dat))
    if (length(aqi_cols) == 0) next
    aqi_mat <- sapply(aqi_cols, function(nm) safe_numeric(dat[[nm]]))
    if (!is.matrix(aqi_mat)) aqi_mat <- matrix(aqi_mat, ncol = 1)
    dat$max_aqi <- apply(aqi_mat, 1, function(v) {
      v <- v[is.finite(v)]
      if (length(v) == 0) return(NA_real_)
      max(v, na.rm = TRUE)
    })
    dat$aqi_score <- vapply(dat$max_aqi, score_airnow_aqi, numeric(1))
    dat <- dat[is.finite(dat$aqi_score) & dat$aqi_score > 0, , drop = FALSE]
    if (nrow(dat) == 0) next
    wi_air <- dat
    break
  }
  if (is.null(wi_air) || nrow(wi_air) == 0) {
    cache_put("derived", "airnow-live-scores", out, ttl_seconds = 1800)
    save_runtime_snapshot(snap_path, out)
    return(out)
  }
  wi_air$Latitude <- safe_numeric(wi_air$Latitude)
  wi_air$Longitude <- safe_numeric(wi_air$Longitude)
  wi_air <- wi_air[is.finite(wi_air$Latitude) & is.finite(wi_air$Longitude), , drop = FALSE]
  if (nrow(wi_air) == 0) {
    cache_put("derived", "airnow-live-scores", out, ttl_seconds = 1800)
    return(out)
  }
  air_sf <- sf::st_as_sf(wi_air, coords = c("Longitude", "Latitude"), crs = 4326)
  air_sf <- ensure_crs_4326(air_sf)
  nearest_idx <- sf::st_nearest_feature(wi_zip_points, air_sf)
  out <- air_sf$aqi_score[nearest_idx]
  names(out) <- wi_zctas$zipcode
  out[!is.finite(out)] <- 0
  cache_put("derived", "airnow-live-scores", out, ttl_seconds = 1800)
  save_runtime_snapshot(snap_path, out)
  out
}
