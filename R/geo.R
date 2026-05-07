# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/geo.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: reference geographies arrive in many archive formats (zip shapefile,
# tar shapefile, KMZ, raw KML/GeoJSON), but downstream code only wants an sf.
# What: returns an sf object read from the appropriate file inside the
# archive; throws if no compatible payload is found.
# How: downloads to a tempfile, dispatches on the URL extension to unzip/
# untar as needed, and reads the first matching .shp or .kml via
# read_sf_quietly.
# When: low-level helper for read_reference_sf and read_latest_sf when the
# local geopackage is missing or stale.
# Impact: an unsupported extension throws and the loader caller falls back
# to its own error handling, typically resulting in an empty layer.
download_unzip_read_sf <- function(url, user_agent = NOAA_USER_AGENT) {
  clean_url <- sub("\\?.*$", "", url)
  ext <- tolower(tools::file_ext(clean_url))
  tmp_file <- tempfile(fileext = if (nzchar(ext)) paste0(".", ext) else "")
  tmp_dir <- tempfile("ref_geo_")
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  req <- httr2::request(url)
  req <- httr2::req_user_agent(req, user_agent)
  req <- httr2::req_timeout(req, 240)
  req <- httr2::req_retry(req, max_tries = 3)
  httr2::req_perform(req, path = tmp_file)

  if (ext == "zip") {
    utils::unzip(tmp_file, exdir = tmp_dir)
    shp_matches <- list.files(tmp_dir, pattern = "\\.shp$", recursive = TRUE, full.names = TRUE)
    if (length(shp_matches) == 0) stop(sprintf("Downloaded archive did not contain a shapefile: %s", url), call. = FALSE)
    return(read_sf_quietly(shp_matches[1], quiet = TRUE))
  }
  if (ext %in% c("tar", "tgz", "gz")) {
    utils::untar(tmp_file, exdir = tmp_dir)
    shp_matches <- list.files(tmp_dir, pattern = "\\.shp$", recursive = TRUE, full.names = TRUE)
    if (length(shp_matches) == 0) stop(sprintf("Downloaded archive did not contain a shapefile: %s", url), call. = FALSE)
    return(read_sf_quietly(shp_matches[1], quiet = TRUE))
  }
  if (ext == "kmz") {
    utils::unzip(tmp_file, exdir = tmp_dir)
    kml_matches <- list.files(tmp_dir, pattern = "\\.kml$", recursive = TRUE, full.names = TRUE)
    if (length(kml_matches) == 0) stop(sprintf("Downloaded KMZ did not contain a KML: %s", url), call. = FALSE)
    return(suppressWarnings(read_sf_quietly(kml_matches[1], quiet = TRUE)))
  }
  if (ext %in% c("kml", "geojson", "json")) {
    return(suppressWarnings(read_sf_quietly(tmp_file, quiet = TRUE)))
  }
  stop(sprintf("Unsupported reference format for %s", url), call. = FALSE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns x reprojected to CRS 4326, or x with CRS assigned to 4326
# if it had none.
# How: sf geometry op + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
ensure_crs_4326 <- function(x) {
  if (is.null(x)) return(x)
  crs <- suppressWarnings(sf::st_crs(x))
  if (is.na(crs)) return(sf::st_set_crs(x, 4326))
  if (isTRUE(crs$epsg == 4326)) return(x)
  suppressWarnings(sf::st_transform(x, 4326))
}

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Renames the active sf geometry column to target_name (default
# "geometry") so downstream code can rely on a stable name.
# How: sf geometry op + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_sf_geometry_column <- function(x, target_name = "geometry") {
  if (is.null(x) || !inherits(x, "sf")) return(x)
  geom_col <- attr(x, "sf_column")
  if (!nzchar(geom_col %||% "") || identical(geom_col, target_name)) return(x)
  names(x)[names(x) == geom_col] <- target_name
  attr(x, "sf_column") <- target_name
  x
}

# Why: shapefiles from external publishers commonly contain self-intersections
# or invalid rings that crash sf::st_intersects.
# What: returns x with valid geometries in CRS 4326 and empty rows removed;
# returns the original x unchanged on persistent failure.
# How: project to a planar CRS (default Albers Equal Area, 5070), st_make_valid
# there, then transform back to 4326; falls back to make_valid on the
# original if the projection step fails.
# When: invoked by read_reference_sf and read_latest_sf right after the raw
# download is parsed and before it gets cached.
# Impact: skipping repair propagates topology errors into every overlay
# operation; the planar repair is the only reliable path for huge polygons.
repair_external_sf <- function(x, projected_epsg = 5070) {
  if (is.null(x) || !inherits(x, "sf") || nrow(x) == 0) return(x)
  x <- ensure_crs_4326(x)
  repaired <- tryCatch(
    {
      projected <- suppressWarnings(sf::st_transform(x, projected_epsg))
      projected <- suppressWarnings(sf::st_make_valid(projected))
      suppressWarnings(sf::st_transform(projected, 4326))
    },
    error = function(e) {
      tryCatch(suppressWarnings(sf::st_make_valid(x)), error = function(e2) x)
    }
  )
  empty_idx <- tryCatch(sf::st_is_empty(repaired), error = function(e) rep(FALSE, nrow(repaired)))
  if (length(empty_idx) == nrow(repaired) && any(empty_idx, na.rm = TRUE)) {
    repaired <- repaired[!empty_idx, , drop = FALSE]
  }
  repaired
}

# Why: sf::st_intersects can throw under S2 mode for noisy polygons; we want a
# version that always returns a sgbp-shaped result.
# What: returns the same list-of-integer result as sf::st_intersects (one
# element per row of x), empty when either input is empty.
# How: tries the default S2 path, and on error transiently disables S2
# (with on.exit restoration) before retrying.
# When: used in spatial joins between alerts/zones/ZCTAs where one side may
# come from a noisy external source.
# Impact: returning empty lists silently drops attributes during join, which
# manifests as missing alerts on the map.
safe_st_intersects <- function(x, y) {
  if (is.null(x) || is.null(y) || nrow(x) == 0 || nrow(y) == 0) {
    return(rep(list(integer(0)), if (is.null(x)) 0L else nrow(x)))
  }
  tryCatch(
    suppressWarnings(sf::st_intersects(x, y)),
    error = function(e) {
      old_s2 <- sf::sf_use_s2()
      on.exit(suppressMessages(sf::sf_use_s2(old_s2)), add = TRUE)
      suppressMessages(sf::sf_use_s2(FALSE))
      suppressWarnings(sf::st_intersects(x, y))
    }
  )
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns sf::st_point_on_surface points in CRS 4326 by computing in
# a planar projection (default 5070) for accuracy.
# How: cache lookup + put + sf geometry op + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
point_on_surface_lonlat <- function(x, projected_epsg = 5070) {
  if (is.null(x) || nrow(x) == 0) return(x)
  x <- ensure_crs_4326(x)
  projected <- suppressWarnings(sf::st_transform(x, projected_epsg))
  pts <- suppressWarnings(sf::st_point_on_surface(projected))
  suppressWarnings(sf::st_transform(pts, 4326))
}

# Why: long-lived reference geographies (counties, ZCTAs) belong in a
# 3-tier cache: in-memory, on-disk snapshot, and remote fetch.
# What: returns the cached or freshly-downloaded sf, with side-effects
# updating both the live cache and the on-disk snapshot.
# How: cache_get -> load_runtime_snapshot (24h) -> download_unzip_read_sf +
# repair_external_sf, hydrating each tier on the way down.
# When: called by reference loaders during startup or on first reactive
# access to a layer.
# Impact: a missing local snapshot forces a slow cold fetch; a corrupt one
# silently propagates bad geometry until the snapshot ages out.
read_reference_sf <- function(namespace, key, url) {
  cached <- cache_get(namespace, key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("%s_%s", namespace, key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 24 * 3600)
  if (!is.null(persisted)) {
    cache_put(namespace, key, persisted, ttl_seconds = 24 * 3600)
    return(persisted)
  }
  obj <- repair_external_sf(download_unzip_read_sf(url))
  cache_put(namespace, key, obj, ttl_seconds = 24 * 3600)
  save_runtime_snapshot(snap_path, obj)
  obj
}

# Why: short-lived geographies (HeatRisk KML, daily flood outlooks) need the
# same 3-tier cache pattern as reference data, but with a tunable TTL.
# What: returns the cached/refreshed sf, with TTL applied to both the live
# cache and the staleness check on the on-disk snapshot.
# How: identical structure to read_reference_sf but parameterised on
# ttl_seconds (default 3600).
# When: called by hourly/short-cycle layer builders (HeatRisk, FFG, etc.).
# Impact: too-long TTL freezes a stale layer, too-short hammers the source
# and slows redraws.
read_latest_sf <- function(namespace, key, url, ttl_seconds = 3600) {
  cached <- cache_get(namespace, key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("%s_%s", namespace, key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = ttl_seconds)
  if (!is.null(persisted)) {
    cache_put(namespace, key, persisted, ttl_seconds = ttl_seconds)
    return(persisted)
  }
  obj <- repair_external_sf(download_unzip_read_sf(url))
  cache_put(namespace, key, obj, ttl_seconds = ttl_seconds)
  save_runtime_snapshot(snap_path, obj)
  obj
}

# Why: some reference layers have multiple mirror URLs; we want to try them
# in order rather than fail on the first transient outage.
# What: returns the first sf successfully downloaded, repaired, and cached;
# rethrows the last error if every URL fails.
# How: iterates urls, captures errors via tryCatch into last_error, returns
# on the first non-NULL result.
# When: used for layers with known unreliable primary endpoints.
# Impact: silent fallback to a secondary source means data versioning may
# vary; ordering urls correctly is critical for canonical results.
read_reference_sf_fallback <- function(namespace, key, urls) {
  cached <- cache_get(namespace, key)
  if (!is.null(cached)) return(cached)
  last_error <- NULL
  for (url in as.character(urls)) {
    obj <- tryCatch(
      repair_external_sf(download_unzip_read_sf(url)),
      error = function(e) {
        last_error <<- e
        NULL
      }
    )
    if (!is.null(obj)) {
      cache_put(namespace, key, obj, ttl_seconds = 24 * 3600)
      return(obj)
    }
  }
  if (!is.null(last_error)) stop(last_error)
  stop(sprintf("Unable to load reference geography for %s", key), call. = FALSE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the parsed reference geopackage manifest (or NULL if
# missing), cached for 24h, listing which layers are bundled locally.
# How: cache lookup + put + sf geometry op.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
read_reference_manifest <- function() {
  cached <- cache_get("reference", "reference_manifest")
  if (!is.null(cached)) return(cached)
  if (!file.exists(REFERENCE_MANIFEST_PATH)) return(NULL)
  manifest <- safely(jsonlite::fromJSON(REFERENCE_MANIFEST_PATH, simplifyVector = TRUE))
  if (!is.null(manifest)) {
    cache_put("reference", "reference_manifest", manifest, ttl_seconds = 24 * 3600)
  }
  manifest
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE if manifest is missing (assume yes) or explicitly
# lists layer_name in its layers section.
# How: sf geometry op.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
manifest_declares_layer <- function(manifest, layer_name) {
  if (is.null(manifest) || is.null(manifest$layers)) return(TRUE)
  layer_name %in% names(manifest$layers)
}

# Why: ship a local reference geopackage so a fresh checkout works offline
# without contacting any external endpoint.
# What: returns the named layer as an sf in CRS 4326 with a normalised
# geometry column, or NULL if missing/unreadable.
# How: checks the bundled gpkg path and the manifest, then sf::st_read,
# ensure_crs_4326, normalize_sf_geometry_column under tryCatch.
# When: first fallback inside require_reference_layer before any remote
# loader is consulted.
# Impact: a corrupt gpkg silently bumps loading to remote (which may hit
# rate limits) - catch with USE_LOCAL_REFERENCE_ONLY for stricter enforce.
read_local_reference_layer <- function(layer_name, quiet = TRUE) {
  if (!file.exists(REFERENCE_GPKG_PATH)) return(NULL)
  manifest <- read_reference_manifest()
  if (!manifest_declares_layer(manifest, layer_name)) return(NULL)
  tryCatch(
    normalize_sf_geometry_column(ensure_crs_4326(sf::st_read(REFERENCE_GPKG_PATH, layer = layer_name, quiet = quiet))),
    error = function(e) NULL
  )
}

# Why: top-level dispatcher that enforces the local-first reference policy
# while still allowing a remote loader fallback for layers we do not bundle.
# What: returns the layer's sf, or stops with a clear error in strict mode.
# How: tries read_local_reference_layer; if absent and USE_LOCAL_REFERENCE_ONLY
# is set, throws a layer-specific message; otherwise calls remote_loader().
# When: every reference layer accessor in wi_loaders.R (load_reference_geographies,
# load_places, load_roads, load_states) routes through this function.
# Impact: changing the precedence here affects offline-mode reproducibility
# and which version of each layer the running app sees.
require_reference_layer <- function(layer_name, remote_loader = NULL) {
  local_obj <- read_local_reference_layer(layer_name)
  if (!is.null(local_obj)) return(local_obj)
  if (isTRUE(USE_LOCAL_REFERENCE_ONLY)) {
    manifest <- read_reference_manifest()
    if (!file.exists(REFERENCE_GPKG_PATH)) {
      stop(sprintf("Local reference layer '%s' was requested but %s is missing.", layer_name, REFERENCE_GPKG_PATH), call. = FALSE)
    }
    if (!is.null(manifest) && !manifest_declares_layer(manifest, layer_name)) {
      stop(sprintf("Local reference manifest does not declare required layer '%s'.", layer_name), call. = FALSE)
    }
    stop(sprintf("Local reference layer '%s' could not be read from %s.", layer_name, REFERENCE_GPKG_PATH), call. = FALSE)
  }
  if (is.null(remote_loader)) return(NULL)
  remote_loader()
}
