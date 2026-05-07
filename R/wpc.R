# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/wpc.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: downstream callers need this lookup encapsulated so cache + fallback
# handling lives in one place.
# What: Returns the WPC QPF (quantitative precipitation forecast) sf for
# the requested horizon, in CRS 4326, cached for 3 hours.
# How: cache lookup + put.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
get_wpc_qpf_sf <- function(horizon_key = "live") {
  key <- paste0("wpc-qpf-", horizon_key)
  cached <- cache_get("reference", key)
  if (!is.null(cached)) return(cached)
  url <- WPC_QPF_URLS[[horizon_key]] %||% WPC_QPF_URLS[["live"]]
  obj <- tryCatch(read_latest_sf("reference", key, url, ttl_seconds = 3 * 3600), error = function(e) wi_zctas[0, c("zipcode", "geometry")])
  ensure_crs_4326(obj)
}

# Why: downstream callers need this lookup encapsulated so cache + fallback
# handling lives in one place.
# What: Returns the WPC excessive-rainfall flood outlook sf in CRS 4326,
# cached for 6 hours; returns an empty sf on fetch failure.
# How: cache lookup + put.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
get_wpc_flood_outlook_sf <- function() {
  key <- "wpc-flood-outlook"
  cached <- cache_get("reference", key)
  if (!is.null(cached)) return(cached)
  obj <- tryCatch(read_latest_sf("reference", key, WPC_FLOOD_OUTLOOK_URL, ttl_seconds = 6 * 3600), error = function(e) wi_zctas[0, c("zipcode", "geometry")])
  ensure_crs_4326(obj)
}

# Why: WPC winter outlooks come as multiple parallel layers (snowfall,
# accumulation probabilities, etc.) per horizon - we want them all together.
# What: returns a named list of CRS-4326 sf layers for the horizon, each
# cached for 6 hours.
# How: switches WPC_WINTER_URLS by horizon, calls read_latest_sf per layer
# name, and ensures CRS 4326.
# When: invoked by the winter scoring pipeline at horizon refresh time.
# Impact: a missing layer entry collapses to an empty sf and that signal
# silently drops out of the winter total.
get_wpc_winter_sf <- function(horizon_key = "live") {
  key <- paste0("wpc-winter-", horizon_key)
  cached <- cache_get("reference", key)
  if (!is.null(cached)) return(cached)
  urls <- WPC_WINTER_URLS[[horizon_key]] %||% WPC_WINTER_URLS[["live"]]
  out <- list()
  for (nm in names(urls)) {
    sf_obj <- tryCatch(read_latest_sf("reference", paste0(key, "-", nm), urls[[nm]], ttl_seconds = 6 * 3600), error = function(e) wi_zctas[0, c("zipcode", "geometry")])
    out[[nm]] <- ensure_crs_4326(sf_obj)
  }
  cache_put("reference", key, out, ttl_seconds = 6 * 3600)
  out
}

# Why: external sf attributes use inconsistent column names; we want a tolerant probe that accepts regex patterns.
# What: returns the maximum finite numeric value across all columns whose
# names match any of the provided patterns; default if none match.
# How: grepl ignore.case across names(row), then for each hit: numeric -> as.numeric,
# character -> regex-extract numbers, take max.
# When: used inside per-polygon value_fun helpers (qpf_value_from_row etc.).
# Impact: a missing pattern silently returns default and the polygon
# contributes 0 - extending coverage requires updating the patterns list.
extract_named_numeric <- function(row, patterns, default = NA_real_) {
  nms <- names(row)
  hit_idx <- unique(unlist(lapply(patterns, function(p) grep(p, nms, ignore.case = TRUE)), use.names = FALSE))
  if (length(hit_idx) == 0) return(default)
  vals <- c()
  for (idx in hit_idx) {
    v <- row[[idx]][1]
    if (is.numeric(v) && is.finite(v)) vals <- c(vals, as.numeric(v))
    if (is.character(v) || is.factor(v)) {
      nums <- safe_numeric(unlist(regmatches(as.character(v), gregexpr("[0-9]+(?:\\.[0-9]+)?", as.character(v), perl = TRUE))))
      nums <- nums[is.finite(nums)]
      if (length(nums) > 0) vals <- c(vals, max(nums, na.rm = TRUE))
    }
  }
  if (length(vals) == 0) return(default)
  max(vals, na.rm = TRUE)
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps QPF rainfall in inches to a 0..1 score via
# piecewise_score(0.25, 1.0, 2.5).
# How: see body — short helper.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_qpf_inches <- function(inches) {
  piecewise_score(inches, 0.25, 1.0, 2.5)
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a percent probability (0..100) to a 0..1 score via
# piecewise_score(10, 40, 70).
# How: see body — short helper.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_probability_pct <- function(prob_pct) {
  piecewise_score(prob_pct, 10, 40, 70)
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a fire-weather DN (Drought Number/grid code) to a fixed-band
# 0..1 score: >=10 -> 1, >=8 -> 0.8, >=5 -> 0.55, otherwise 0.25.
# How: see body — short helper.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_fire_dn <- function(dn) {
  dn <- safe_numeric(dn)
  if (!is.finite(dn) || dn <= 0) return(0)
  if (dn >= 10) return(1)
  if (dn >= 8) return(0.8)
  if (dn >= 5) return(0.55)
  0.25
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a WPC flood outlook numeric value to 0..1 by val/max(5, val)
# clipped to [0,1] - asymptotic, never quite reaching 1 for small vals.
# How: see body — short helper.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_flood_outlook_value <- function(val) {
  val <- safe_numeric(val)
  if (!is.finite(val) || val <= 0) return(0)
  pmin(1, val / max(5, val))
}

# Why: a uniform spatial-join helper that scores each ZIP by the max value
# returned by value_fun across the polygons it sits in.
# What: returns a length-nrow(zips) numeric vector of per-zip scores (0
# where no polygon contains the ZIP centroid).
# How: repairs sf_obj, projects ZIP centroids if needed, runs
# safe_st_intersects, and for each zip applies value_fun to each hit row,
# keeping the max.
# When: shared by qpf, winter, fire, flood-outlook, FHO, convective, etc.
# Impact: this is the single ZIP-from-polygon scoring path - a regression
# here would skew every external-polygon-based score at once.
assign_polygon_metric <- function(zips, sf_obj, value_fun) {
  scores <- rep(0, nrow(zips))
  if (is.null(sf_obj) || nrow(sf_obj) == 0 || is.null(zips) || nrow(zips) == 0) return(scores)
  sf_obj <- repair_external_sf(sf_obj)
  if (nrow(sf_obj) == 0) return(scores)

  zip_points <- if (identical(zips$zipcode, wi_zctas$zipcode)) {
    wi_zip_points
  } else {
    point_on_surface_lonlat(zips)
  }

  hits <- safe_st_intersects(zip_points, sf_obj)
  if (length(hits) == 0) return(scores)

  for (i in seq_along(hits)) {
    idx <- hits[[i]]
    if (length(idx) == 0) next
    vals <- vapply(
      idx,
      function(j) value_fun(sf::st_drop_geometry(sf_obj[j, , drop = FALSE])),
      numeric(1)
    )
    vals <- vals[is.finite(vals)]
    if (length(vals) > 0) scores[i] <- max(vals, na.rm = TRUE)
  }

  scores
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: value_fun for assign_polygon_metric: extracts a numeric QPF amount
# from the row and runs score_qpf_inches.
# How: regex match.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
qpf_value_from_row <- function(row) {
  val <- extract_named_numeric(row, c("qpf", "amount", "upper", "lower", "value", "label", "contour"))
  if (!is.finite(val)) return(0)
  score_qpf_inches(val)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: value_fun for assign_polygon_metric: pulls a probability
# (auto-scaled if 0..1) from the row and runs score_probability_pct.
# How: regex match + row/element loop + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
winter_prob_value_from_row <- function(row) {
  val <- extract_named_numeric(row, c("prob", "pct", "percent", "value", "label", "contour"))
  if (!is.finite(val)) return(0)
  if (val <= 1) val <- val * 100
  score_probability_pct(val)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: value_fun for assign_polygon_metric: numeric outlook value ->
# score_flood_outlook_value, defaulting to 0.6 when no number is found.
# How: regex match + row/element loop + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
flood_outlook_value_from_row <- function(row) {
  val <- extract_named_numeric(row, c("dn", "risk", "value", "label", "outlook", "flood"))
  if (!is.finite(val)) return(0.6)
  score_flood_outlook_value(val)
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps the NOAA Flood Hazard Outlook (FHO) category text
# ("considerable", "elevated", "limited", etc.) to a fixed 0..1 score.
# How: regex match + sf geometry op + row/element loop + guarded numeric
# coercion.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_fho_category <- function(value) {
  txt <- tolower(trimws(as.character(value %||% "")))
  if (!nzchar(txt)) return(NA_real_)
  if (grepl("considerable|major|significant", txt)) return(1.00)
  if (grepl("elevated|moderate|possible", txt)) return(0.65)
  if (grepl("limited|minor", txt)) return(0.35)
  if (grepl("none|low", txt)) return(0.00)
  NA_real_
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: value_fun: takes max of categorical FHO score and a normalized
# numeric DN score so polygons with either signal score correctly.
# How: cache lookup + put + sf geometry op + row/element loop + branch
# dispatch + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
fho_value_from_row <- function(row) {
  vals <- unlist(row, use.names = FALSE)
  cat_score <- suppressWarnings(max(vapply(vals, score_fho_category, numeric(1)), na.rm = TRUE))
  if (!is.finite(cat_score)) cat_score <- 0
  num_val <- extract_named_numeric(row, c("dn", "risk", "gridcode", "value", "category", "flood"))
  num_score <- if (is.finite(num_val)) pmin(1, pmax(0, num_val / max(3, num_val))) else 0
  pmax(cat_score, num_score, na.rm = TRUE)
}

# Why: NOAA OWP's Flood Hazard Outlook is delivered as an ArcGIS layer; we
# query it bbox-clipped per horizon and cache the repaired sf.
# What: returns a CRS-4326 sf of FHO polygons for the horizon, or empty sf
# on failure; cached for 6h.
# How: builds an esriGeometryEnvelope query against OWP_FHO_BASE_URL with
# the right layer_id, sf::st_read it, and runs repair_external_sf.
# When: called by the flood scoring pipeline.
# Impact: changes to layer_id mapping change which day's outlook is shown -
# currently all horizons share layer 0; future API revs may split them.
get_owp_fho_sf <- function(horizon_key = "live") {
  key <- paste0("owp-fho-", horizon_key)
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  layer_id <- switch(horizon_key %||% "live",
    live = 0L,
    `24h` = 0L,
    `48h` = 0L,
    `72h` = 0L,
    0L
  )
  bbox <- paste(wi_bounds$west, wi_bounds$south, wi_bounds$east, wi_bounds$north, sep = ",")
  url <- sprintf(
    "%s/%s/query?where=1%%3D1&geometry=%s&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=*&returnGeometry=true&f=geojson",
    OWP_FHO_BASE_URL, layer_id, utils::URLencode(bbox, reserved = TRUE)
  )
  sf_obj <- tryCatch(suppressWarnings(sf::st_read(url, quiet = TRUE)), error = function(e) wi_zctas[0, c("zipcode", "geometry")])
  sf_obj <- repair_external_sf(sf_obj)
  cache_put("derived", key, sf_obj, ttl_seconds = 6 * 3600)
  sf_obj
}

# Why: SPC fire-weather outlooks are split across two layers per horizon
# (e.g., critical and elevated areas).
# What: returns a list of repaired CRS-4326 sf objects keyed by ArcGIS
# layer id, cached in memory and on disk for 6 hours.
# How: switches layer_ids by horizon_key, queries each one bbox-clipped,
# repairs, and stores under as.character(lid).
# When: called by the fire-weather scoring pipeline.
# Impact: a swap in the layer-id mapping silently changes which horizon's
# outlook the user sees - SPC has updated this list before.
load_spc_fire_sf <- function(horizon_key = "live") {
  key <- paste0("spc-fire-", horizon_key)
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 6 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", key, persisted, ttl_seconds = 6 * 3600)
    return(persisted)
  }
  layer_ids <- switch(horizon_key %||% "live",
    live = c(1L, 2L),
    `24h` = c(4L, 5L),
    `48h` = c(7L, 8L),
    `72h` = c(10L, 11L),
    c(1L, 2L)
  )
  bbox <- paste(wi_bounds$west, wi_bounds$south, wi_bounds$east, wi_bounds$north, sep = ",")
  out <- list()
  for (lid in layer_ids) {
    url <- sprintf(
      "%s/%s/query?where=1%%3D1&geometry=%s&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=*&returnGeometry=true&f=geojson",
      SPC_FIRE_BASE_URL, lid, utils::URLencode(bbox, reserved = TRUE)
    )
    sf_obj <- safely(suppressWarnings(sf::st_read(url, quiet = TRUE)))
    if (!is.null(sf_obj)) out[[as.character(lid)]] <- repair_external_sf(sf_obj)
  }
  cache_put("derived", key, out, ttl_seconds = 6 * 3600)
  save_runtime_snapshot(snap_path, out)
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: value_fun: pulls numeric DN/gridcode from the row and runs
# score_fire_dn.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
fire_value_from_row <- function(row) {
  dn <- extract_named_numeric(row, c("dn", "gridcode", "value", "label", "risk"))
  if (!is.finite(dn)) return(0)
  score_fire_dn(dn)
}
