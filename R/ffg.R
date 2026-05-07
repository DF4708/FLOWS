# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/ffg.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a Flash Flood Guidance value (inches needed to flood) through
# inv_piecewise_score(4.5, 2.5, 1.0) - lower means worse.
# How: see body — short helper.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_ffg_inches <- function(ffg_inches) {
  ffg_inches <- safe_numeric(ffg_inches)
  if (!is.finite(ffg_inches) || ffg_inches <= 0) return(0)
  inv_piecewise_score(ffg_inches, 4.5, 2.5, 1.0)
}

# Why: ArcGIS REST identify responses can come back in many shapes (raw value,
# results array, attributes table) depending on layer type.
# What: returns the first finite numeric pixel value found, else NA_real_.
# How: walks possible result containers in order, looking under "value",
# then a list of common attribute keys ("Pixel Value", "PixelValue", etc.).
# When: called by arcgis_identify_point_value to coerce the heterogeneous
# JSON into a single number per query.
# Impact: a new attribute name in a future ArcGIS version would silently
# return NA - the candidate list above is the maintenance hot spot.
extract_arcgis_identify_value <- function(payload) {
  if (is.null(payload)) return(NA_real_)
  if (is.atomic(payload) && !is.list(payload)) {
    direct <- safe_numeric(payload[[1]])
    return(if (is.finite(direct)) direct else NA_real_)
  }

  results <- NULL
  if (is.list(payload) && !is.data.frame(payload) && !is.null(payload$results)) {
    results <- payload$results
  } else if (is.data.frame(payload) && "results" %in% names(payload)) {
    results <- payload$results
  } else if (is.data.frame(payload)) {
    results <- split(payload, seq_len(nrow(payload)))
  } else if (is.list(payload)) {
    results <- payload
  }

  if (is.data.frame(results)) {
    results <- split(results, seq_len(nrow(results)))
  }
  if (!is.list(results) || length(results) == 0) return(NA_real_)

  for (res in results) {
    if (is.atomic(res) && !is.list(res)) {
      direct <- safe_numeric(res[[1]])
      if (is.finite(direct)) return(direct)
      next
    }

    direct <- safe_numeric(extract_named_value(res, c("value", "Value"), default = NA_real_))
    if (is.finite(direct)) return(direct)
    attrs <- extract_named_value(res, c("attributes", "Attributes"), default = list())
    if (is.data.frame(attrs)) attrs <- as.list(attrs[1, , drop = TRUE])
    if (!is.list(attrs)) attrs <- list()
    for (nm in c("Pixel Value", "PixelValue", "value", "VALUE", "Gray_Index", "GRAY_INDEX", "gridcode", "GridCode")) {
      v <- safe_numeric(attrs[[nm]] %||% NA_real_)
      if (is.finite(v)) return(v)
    }
  }
  NA_real_
}

# Why: probe the FFG ArcGIS image service at a single (lon, lat) for a layer
# without downloading the full raster.
# What: returns the numeric raster value at the point, or NA_real_ on any
# request/parse error.
# How: builds an /identify URL with a small synthetic mapExtent box around
# the point, calls http_json_simple, hands payload to extract_arcgis_identify_value.
# When: invoked per ZCTA by fetch_ffg_zip_sensitivity (cold-fetch path).
# Impact: invalid extent or wkid produces NA across all queries; the small
# delta of 0.05 deg controls how local the identify is.
arcgis_identify_point_value <- function(service_url, layer_id, lon, lat) {
  if (!is.finite(lon) || !is.finite(lat)) return(NA_real_)
  geom_json <- sprintf('{"x":%.6f,"y":%.6f,"spatialReference":{"wkid":4326}}', lon, lat)
  delta <- 0.05
  url <- build_url_with_query(
    paste0(service_url, "/identify"),
    list(
      geometry = geom_json,
      geometryType = "esriGeometryPoint",
      sr = "4326",
      layers = paste0("all:", as.integer(layer_id)),
      tolerance = "1",
      mapExtent = sprintf("%.6f,%.6f,%.6f,%.6f", lon - delta, lat - delta, lon + delta, lat + delta),
      imageDisplay = "400,400,96",
      returnGeometry = "false",
      f = "pjson"
    )
  )
  payload <- safely(http_json_simple(url))
  if (is.null(payload)) return(NA_real_)
  extract_arcgis_identify_value(payload)
}

# Why: per-ZIP flash-flood sensitivity blends three FFG durations (1h/3h/6h)
# into a single score that flags ZIPs needing little rain to flood.
# What: returns a named numeric vector (one entry per ZCTA, zip codes as
# names) of 0..1 sensitivity scores.
# How: caches in "derived" with 24h on-disk snapshot; the cold-fetch path
# (currently disabled by allow_cold_fetch=FALSE) would call ArcGIS identify
# per ZIP per duration and combine via weighted pmax.
# When: called by the flood-component scoring pipeline on layer build.
# Impact: with cold fetch off, every ZIP returns 0 - removing this gate is
# expensive (many synchronous identify calls) and should be deliberate.
fetch_ffg_zip_sensitivity <- function() {
  key <- "ffg-zip-sensitivity"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 6 * 3600)
  if (!is.null(persisted)) {
    cache_put("derived", key, persisted, ttl_seconds = 3600)
    return(persisted)
  }
  out <- setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  coords <- sf::st_coordinates(wi_zip_points)
  if (is.null(coords) || nrow(coords) != nrow(wi_zctas)) {
    cache_put("derived", key, out, ttl_seconds = 3600)
    return(out)
  }
  allow_cold_fetch <- FALSE
  if (!isTRUE(allow_cold_fetch)) {
    cache_put("derived", key, out, ttl_seconds = 10 * 60)
    return(out)
  }

  layer_scores <- lapply(names(FFG_LAYER_IDS), function(duration_name) rep(NA_real_, nrow(wi_zctas)))
  names(layer_scores) <- names(FFG_LAYER_IDS)
  for (i in seq_len(nrow(coords))) {
    lon <- coords[i, "X"]
    lat <- coords[i, "Y"]
    for (duration_name in names(FFG_LAYER_IDS)) {
      raw_val <- arcgis_identify_point_value(FFG_SERVICE_URL, FFG_LAYER_IDS[[duration_name]], lon, lat)
      layer_scores[[duration_name]][i] <- score_ffg_inches(raw_val)
    }
  }

  out <- pmax(
    0.25 * (layer_scores[["1h"]] %||% 0),
    0.50 * (layer_scores[["3h"]] %||% 0),
    0.35 * (layer_scores[["6h"]] %||% 0),
    na.rm = TRUE
  )
  out[!is.finite(out)] <- 0
  names(out) <- wi_zctas$zipcode
  cache_put("derived", key, out, ttl_seconds = 3600)
  save_runtime_snapshot(snap_path, out)
  out
}
