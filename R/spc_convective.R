# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/spc_convective.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Maps an SPC probability (0..1 or 0..100) to a 0..1 risk via piecewise_score(5, 15, 30) - thresholds chosen on the percentage scale.
score_convective_probability <- function(prob) {
  prob <- safe_numeric(prob)
  if (!is.finite(prob)) return(0)
  if (prob <= 1) prob <- prob * 100
  piecewise_score(prob, 5, 15, 30)
}

# Maps an SPC categorical label (TSTM/MRGL/SLGT/ENH/MDT/HIGH) to a fixed 0..1 score via the standard tier mapping.
score_convective_category <- function(cat_value) {
  txt <- toupper(trimws(safe_string(cat_value)))
  if (!nzchar(txt)) return(0)
  if (grepl("HIGH", txt, fixed = TRUE)) return(1.00)
  if (grepl("MDT", txt, fixed = TRUE) || grepl("MODERATE", txt, fixed = TRUE)) return(0.93)
  if (grepl("ENH", txt, fixed = TRUE) || grepl("ENHANCED", txt, fixed = TRUE)) return(0.82)
  if (grepl("SLGT", txt, fixed = TRUE) || grepl("SLIGHT", txt, fixed = TRUE)) return(RISK_YELLOW_MIN)
  if (grepl("MRGL", txt, fixed = TRUE) || grepl("MARGINAL", txt, fixed = TRUE)) return(0.52)
  if (grepl("TSTM", txt, fixed = TRUE) || grepl("THUNDER", txt, fixed = TRUE)) return(0.15)
  0
}

# Why: SPC outlook polygons mix categorical labels and numeric probabilities;
# we want a single 0..1 score per polygon for the spatial join.
# What: returns max(category score, probability score + 0.15 sig bonus)
# clipped to [0,1].
# How: collapses the row to text, runs score_convective_category on each
# value, runs score_convective_probability on the first numeric attribute,
# and adds a +0.15 if "SIGNIFICANT" or "SIG" appears in the text.
# When: called by assign_polygon_metric on each SPC polygon during the
# convective-layer build.
# Impact: changes here re-tune how the SPC layer competes with other
# convective inputs (lightning, radar, wind).
convective_value_from_row <- function(row) {
  txt <- toupper(paste(unlist(row, use.names = FALSE), collapse = " | "))
  cat_score <- max(vapply(unlist(row, use.names = FALSE), score_convective_category, numeric(1)), na.rm = TRUE)
  if (!is.finite(cat_score)) cat_score <- 0
  prob_val <- extract_named_numeric(row, c("prob", "percentage", "percent", "value", "label", "contour", "gridcode", "dn"))
  prob_score <- if (is.finite(prob_val)) score_convective_probability(prob_val) else 0
  sig_bonus <- if (grepl("SIGNIFICANT|SIG", txt)) 0.15 else 0
  pmin(1, max(cat_score, prob_score + sig_bonus, na.rm = TRUE))
}

# Why: SPC publishes Day-1/2/3+ convective outlook polygons on different
# ArcGIS layers; we need to pick the right layer set per horizon.
# What: returns a named list of repaired sf objects (categorical, tornado,
# hail, wind, etc.) for the horizon, cached for 6 hours.
# How: switches on horizon_key for the layer-id mapping, queries each layer
# clipped to wi_bounds bbox via geojson, repairs each result via
# repair_external_sf, persists snapshot.
# When: invoked once per cycle by the convective scoring pipeline.
# Impact: a wrong layer-id mapping silently swaps in the wrong day's
# outlooks - particularly easy to miss between Day-2 and Day-3.
load_spc_convective_sf <- function(horizon_key = "live") {
  key <- paste0("spc-convective-", horizon_key)
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 6 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", key, persisted, ttl_seconds = 6 * 3600)
    return(persisted)
  }
  layer_ids <- switch(horizon_key %||% "live",
    live = c(categorical = 1L, tornado = 3L, hail = 5L, wind = 7L),
    `24h` = c(categorical = 1L, tornado = 3L, hail = 5L, wind = 7L),
    `48h` = c(categorical = 9L, tornado = 11L, hail = 13L, wind = 15L),
    `72h` = c(categorical = 17L, probabilistic = 19L, significant = 18L),
    c(categorical = 1L, tornado = 3L, hail = 5L, wind = 7L)
  )
  bbox <- paste(wi_bounds$west, wi_bounds$south, wi_bounds$east, wi_bounds$north, sep = ",")
  # The four ArcGIS layers are independent and individually cacheable; running
  # them in parallel cuts cold latency from ~4x serial to one parallel batch.
  fetch_one <- function(nm) {
    lid <- layer_ids[[nm]]
    url <- sprintf(
      "%s/%s/query?where=1%%3D1&geometry=%s&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=*&returnGeometry=true&f=geojson",
      SPC_CONVECTIVE_BASE_URL, lid, utils::URLencode(bbox, reserved = TRUE)
    )
    sf_obj <- safely(suppressWarnings(sf::st_read(url, quiet = TRUE)))
    if (is.null(sf_obj)) NULL else repair_external_sf(sf_obj)
  }
  use_parallel <- .Platform$OS.type != "windows"
  layer_names <- names(layer_ids)
  fetched <- if (use_parallel && length(layer_names) > 1L) {
    parallel::mclapply(layer_names, fetch_one,
                       mc.cores = min(4L, length(layer_names)), mc.preschedule = FALSE)
  } else {
    lapply(layer_names, fetch_one)
  }
  names(fetched) <- layer_names
  out <- fetched[!vapply(fetched, is.null, logical(1))]
  cache_put("derived", key, out, ttl_seconds = 6 * 3600)
  save_runtime_snapshot(snap_path, out)
  out
}
