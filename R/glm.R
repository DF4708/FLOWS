# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/glm.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns x truncated down to the hour boundary in UTC
# (minutes/seconds zeroed) for GLM bucket prefix construction.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
glm_floor_to_hour <- function(x) {
  lt <- as.POSIXlt(x, tz = "UTC")
  lt$min <- 0L
  lt$sec <- 0
  as.POSIXct(lt, tz = "UTC")
}

# Why: GOES GLM lightning data is published in S3 directories keyed by year/
# day-of-year/hour, so a time window must be turned into a list of prefixes.
# What: returns a unique character vector of S3 prefixes covering every hour
# from now-lookback to now (UTC).
# How: floors both endpoints to the hour, generates an hourly seq, formats
# each timestamp into the GLM_PRODUCT_PREFIX/Y/jjj/HH/ pattern.
# When: called by glm_list_bucket_keys when scanning S3 for recent flash
# files.
# Impact: a wrong format here produces zero-key results and silent loss of
# the lightning overlay; the unique() call avoids duplicate scans on day
# rollover.
glm_hour_prefixes <- function(lookback_minutes = GLM_LOOKBACK_MINUTES) {
  end_hour <- glm_floor_to_hour(Sys.time())
  start_hour <- glm_floor_to_hour(Sys.time() - max(lookback_minutes, 5) * 60)
  seq_hours <- seq(from = start_hour, to = end_hour, by = "hour")
  unique(vapply(seq_hours, function(ts) {
    sprintf("%s/%s/%s/%s/", GLM_PRODUCT_PREFIX, format(ts, "%Y", tz = "UTC"), format(ts, "%j", tz = "UTC"), format(ts, "%H", tz = "UTC"))
  }, character(1)))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Extracts the bare keys from an S3 ListObjectsV2 XML response -
# lightweight regex parser, no XML lib dependency.
# How: regex match + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
glm_parse_s3_keys <- function(xml_text) {
  if (is.null(xml_text) || !nzchar(xml_text)) return(character(0))
  matches <- gregexpr("<Key>([^<]+)</Key>", xml_text, perl = TRUE)
  vals <- regmatches(xml_text, matches)[[1]] %||% character(0)
  if (length(vals) == 0) return(character(0))
  sub("^<Key>|</Key>$", "", vals)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Parses the "_sYYYYJJJHHMMSS" timestamp embedded in a GOES GLM
# filename and returns it as a UTC POSIXct (or NA on bad keys).
# How: regex match + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
glm_object_start_time <- function(key) {
  key <- safe_string(key)
  stamp <- sub(".*_s([0-9]{13}).*", "\\1", key, perl = TRUE)
  if (!grepl("^[0-9]{13}$", stamp)) return(as.POSIXct(NA, tz = "UTC"))
  year <- substr(stamp, 1, 4)
  yday <- substr(stamp, 5, 7)
  hh <- substr(stamp, 8, 9)
  mm <- substr(stamp, 10, 11)
  ss <- substr(stamp, 12, 13)
  suppressWarnings(as.POSIXct(sprintf("%s-%s %s:%s:%s", year, yday, hh, mm, ss), format = "%Y-%j %H:%M:%S", tz = "UTC"))
}

# Why: enumerate GLM flash files in an S3 bucket without using the AWS SDK -
# we just hit the public list-type=2 endpoint per prefix.
# What: returns a unique character vector of S3 keys across all prefixes
# (empty character() if every list call fails).
# How: builds a list URL per prefix, fetches XML via http_text under
# tryCatch, runs glm_parse_s3_keys on each.
# When: called by glm_recent_object_catalog before deciding which files to
# pull and decode.
# Impact: a 5xx from S3 silently yields fewer keys (and fewer flashes),
# which the caller treats as "no lightning right now".
glm_list_bucket_keys <- function(bucket, prefixes = glm_hour_prefixes()) {
  keys <- character(0)
  for (prefix in prefixes) {
    url <- sprintf("https://%s.s3.amazonaws.com/?list-type=2&prefix=%s&max-keys=1000", bucket, utils::URLencode(prefix, reserved = TRUE))
    xml_txt <- safely(http_text(url, user_agent = NOAA_USER_AGENT))
    keys <- c(keys, glm_parse_s3_keys(xml_txt))
  }
  unique(keys)
}

# Why: produce a small, sorted manifest of the most recent GLM flash files we
# should fetch, capped at GLM_MAX_FILES_PER_PASS for performance.
# What: returns a data.frame(bucket, key, start_time, url) ordered by
# decreasing start_time, or empty if no bucket has fresh files.
# How: iterates GLM_GOES_BUCKETS, lists keys, parses timestamps, filters
# within lookback window, sorts, and truncates.
# When: kicked off at the top of fetch_glm_lightning_scores per its TTL.
# Impact: an empty catalogue collapses lightning to all-zero scores; the
# bucket fallback ordering decides which GOES satellite the data prefers.
glm_recent_object_catalog <- function() {
  lookback_secs <- GLM_LOOKBACK_MINUTES * 60
  cutoff <- Sys.time() - lookback_secs
  for (bucket in GLM_GOES_BUCKETS) {
    keys <- glm_list_bucket_keys(bucket)
    if (length(keys) == 0) next
    starts <- vapply(keys, glm_object_start_time, as.POSIXct(NA, tz = "UTC"))
    keep <- is.finite(as.numeric(starts)) & starts >= cutoff
    if (!any(keep)) next
    keys <- keys[keep]
    starts <- starts[keep]
    ord <- order(starts, decreasing = TRUE)
    keys <- keys[ord]
    starts <- starts[ord]
    if (length(keys) > GLM_MAX_FILES_PER_PASS) {
      keys <- keys[seq_len(GLM_MAX_FILES_PER_PASS)]
      starts <- starts[seq_len(GLM_MAX_FILES_PER_PASS)]
    }
    return(data.frame(
      bucket = rep(bucket, length(keys)),
      key = keys,
      start_time = starts,
      url = sprintf("https://%s.s3.amazonaws.com/%s", bucket, keys),
      stringsAsFactors = FALSE
    ))
  }
  data.frame(bucket = character(0), key = character(0), start_time = as.POSIXct(character(0), tz = "UTC"), url = character(0), stringsAsFactors = FALSE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Reads the first variable from an open ncdf4 handle whose name
# appears in candidates; returns NULL if none match or the read errors.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
glm_first_available_var <- function(nc, candidates = character(0)) {
  vars <- names(nc$var %||% list())
  match_name <- candidates[candidates %in% vars][1] %||% NA_character_
  if (!nzchar(match_name)) return(NULL)
  safely(ncdf4::ncvar_get(nc, match_name))
}

# Why: GLM publishes flashes/groups/events in NetCDF; we want a uniform sf of
# point flashes, accepting whichever lat/lon variable names exist.
# What: returns an sf with one POINT per flash inside (or near) Wisconsin's
# bbox in CRS 4326, or NULL if the file is unparseable or empty.
# How: downloads to a tempfile, opens via ncdf4, picks the first available
# lat/lon variable family, filters by finite + bbox.
# When: called from fetch_glm_lightning_scores once per file in the
# recent-object catalog.
# Impact: a missing ncdf4 dependency or unfamiliar variable names returns
# NULL and forfeits that file's contribution to the lightning score.
read_glm_flash_points <- function(url) {
  if (!requireNamespace("ncdf4", quietly = TRUE)) return(NULL)
  tmp_file <- safely(download_to_tempfile(url, fileext = ".nc"))
  if (is.null(tmp_file) || !file.exists(tmp_file)) return(NULL)
  on.exit(unlink(tmp_file), add = TRUE)
  nc <- safely(ncdf4::nc_open(tmp_file))
  if (is.null(nc)) return(NULL)
  on.exit(try(ncdf4::nc_close(nc), silent = TRUE), add = TRUE)
  lat_vals <- glm_first_available_var(nc, c("flash_lat", "flash_latitude", "event_lat", "group_lat"))
  lon_vals <- glm_first_available_var(nc, c("flash_lon", "flash_longitude", "event_lon", "group_lon"))
  if (is.null(lat_vals) || is.null(lon_vals)) return(NULL)
  lat_vals <- safe_numeric(lat_vals)
  lon_vals <- safe_numeric(lon_vals)
  keep <- is.finite(lat_vals) & is.finite(lon_vals)
  if (!any(keep)) return(NULL)
  df <- data.frame(lon = lon_vals[keep], lat = lat_vals[keep], stringsAsFactors = FALSE)
  bbox_keep <- df$lat >= (wi_bounds$south - 1) & df$lat <= (wi_bounds$north + 1) & df$lon >= (wi_bounds$west - 1) & df$lon <= (wi_bounds$east + 1)
  df <- df[bbox_keep, , drop = FALSE]
  if (nrow(df) == 0) return(NULL)
  sf::st_as_sf(df, coords = c("lon", "lat"), crs = 4326)
}

# Why: convert GOES GLM flash points into a per-ZIP recency-weighted lightning
# risk score that the composite map can consume.
# What: returns a list(scores, labels) with one entry per ZCTA - scores are
# 0..1, labels are popup-ready text or NA when score == 0.
# How: for each catalogued file, snaps each flash to its nearest ZIP centroid
# (in EPSG:5070), accumulates exp-decay-weighted counts by 12-min half-life,
# and runs piecewise_score(1.5, 6, 15).
# When: cached for 30 minutes; called by the convective hazard pipeline.
# Impact: the decay constant and piecewise thresholds set how aggressively
# brief storms light up the map; missing ncdf4 silently zeroes everything.
fetch_glm_lightning_scores <- function() {
  cached <- cache_get("derived", "glm-lightning-scores")
  if (!is.null(cached)) return(cached)
  scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  labels <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  if (!requireNamespace("ncdf4", quietly = TRUE)) {
    out <- list(scores = scores, labels = labels)
    cache_put("derived", "glm-lightning-scores", out, ttl_seconds = 30 * 60)
    return(out)
  }
  catalog <- glm_recent_object_catalog()
  if (nrow(catalog) == 0) {
    out <- list(scores = scores, labels = labels)
    cache_put("derived", "glm-lightning-scores", out, ttl_seconds = 30 * 60)
    return(out)
  }
  zip_pts_proj <- wi_zip_points_proj
  accum <- rep(0, nrow(wi_zctas))
  freshest_age <- rep(Inf, nrow(wi_zctas))
  # Parallelize the per-file S3 download + ncdf4 read. Each file is ~MB and
  # the 45-second download timeout serial-stacked could block 13+ minutes
  # in the worst case. mclapply caps cold latency at one batch per worker.
  use_parallel <- .Platform$OS.type != "windows"
  workers <- if (use_parallel) min(6L, max(1L, nrow(catalog))) else 1L
  flash_results <- if (workers > 1L) {
    parallel::mclapply(
      seq_len(nrow(catalog)),
      function(i) safely(read_glm_flash_points(catalog$url[i])),
      mc.cores = workers, mc.preschedule = FALSE
    )
  } else {
    lapply(seq_len(nrow(catalog)),
           function(i) safely(read_glm_flash_points(catalog$url[i])))
  }
  for (i in seq_len(nrow(catalog))) {
    flash_sf <- flash_results[[i]]
    if (is.null(flash_sf) || nrow(flash_sf) == 0) next
    age_minutes <- pmax(0, as.numeric(difftime(Sys.time(), catalog$start_time[i], units = "mins")))
    age_decay <- exp(-age_minutes / 12)
    flash_proj <- suppressWarnings(sf::st_transform(flash_sf, 5070))
    nearest_idx <- suppressWarnings(sf::st_nearest_feature(flash_proj, zip_pts_proj))
    nearest_idx[!is.finite(nearest_idx)] <- NA_integer_
    nearest_idx <- nearest_idx[is.finite(nearest_idx)]
    if (length(nearest_idx) == 0) next
    tab <- table(nearest_idx)
    hit_idx <- as.integer(names(tab))
    hit_counts <- as.numeric(tab)
    accum[hit_idx] <- accum[hit_idx] + hit_counts * age_decay
    freshest_age[hit_idx] <- pmin(freshest_age[hit_idx], age_minutes)
  }
  if (any(accum > 0)) {
    # Vectorised (no per-element vapply loop) — byte-identical to
    # vapply(piecewise_score) for scalar thresholds; see R/scoring.R.
    raw_scores <- vector_piecewise_score(accum, 1.5, 6, 15)
    scores[] <- raw_scores
    labels[raw_scores > 0] <- ifelse(
      is.finite(freshest_age[raw_scores > 0]),
      sprintf("Recent GOES GLM lightning detected near this ZIP within %.0f minutes.", pmax(1, round(freshest_age[raw_scores > 0]))),
      "Recent GOES GLM lightning detected near this ZIP."
    )
  }
  out <- list(scores = scores, labels = labels)
  cache_put("derived", "glm-lightning-scores", out, ttl_seconds = 30 * 60)
  out
}
