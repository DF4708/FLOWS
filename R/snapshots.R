# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/snapshots.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: warm-start the very first map paint by loading the previous session's
# live + default-primary snapshot before any reactives fire.
# What: returns the cached payload (zip polygons + metadata) or NULL if the
# horizon/primary doesn't match defaults or the snapshot is stale.
# How: gates on horizon == "live" and primary == DEFAULT_PRIMARY_MAP, then
# loads STARTUP_MAP_SNAPSHOT_PATH via load_runtime_snapshot.
# When: invoked at server.R startup before the live build completes.
# Impact: returning stale data here briefly displays a previous-tick map
# while the real build runs; the gating prevents wrong-horizon paints.
load_startup_map_snapshot <- function(horizon_key = "live", primary_map = DEFAULT_PRIMARY_MAP, max_age_seconds = STARTUP_SNAPSHOT_MAX_AGE_SECONDS) {
  primary_map <- normalize_primary_map(primary_map)
  if (!identical(horizon_key %||% "live", "live") || !identical(primary_map, DEFAULT_PRIMARY_MAP)) return(NULL)
  snap <- load_runtime_snapshot(STARTUP_MAP_SNAPSHOT_PATH, max_age_seconds = max_age_seconds)
  if (is.null(snap)) return(NULL)
  payload <- snap$payload %||% snap
  # Strip any legacy 511 travel-delay reason strings that pre-fix
  # snapshots may have baked into modeled road popups. Travel-time delay
  # is a congestion signal, not a safety hazard, so the warmed startup
  # paint must not surface it. The sanitizer drops the row's bespoke
  # text back to the generic "All clear." fallback the rest of the
  # pipeline expects.
  if (!is.null(payload$roads) && inherits(payload$roads, "sf") && nrow(payload$roads) > 0 &&
      "driving_reason_text" %in% names(payload$roads)) {
    bad <- is_travel_delay_reason(payload$roads$driving_reason_text)
    if (any(bad, na.rm = TRUE)) {
      payload$roads$driving_reason_text[bad] <- "All clear."
      if ("road_source" %in% names(payload$roads)) {
        payload$roads$road_source[bad] <- "Modeled ZIP risk"
      }
      if ("official_cause_text" %in% names(payload$roads)) {
        payload$roads$official_cause_text[bad] <- "none"
      }
    }
  }
  payload
}

# Why: a downstream session needs the value persisted so the next process
# can warm-start instead of recomputing from scratch.
# What: Persists the live + default-primary map payload to disk so
# subsequent restarts can warm-start; only saves when payload$polys has
# rows.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
save_startup_map_snapshot <- function(payload, horizon_key = "live", primary_map = DEFAULT_PRIMARY_MAP) {
  primary_map <- normalize_primary_map(primary_map)
  if (!identical(horizon_key %||% "live", "live") || !identical(primary_map, DEFAULT_PRIMARY_MAP)) return(invisible(FALSE))
  if (is.null(payload) || is.null(payload$polys) || !inherits(payload$polys, "sf") || nrow(payload$polys) == 0) return(invisible(FALSE))
  save_runtime_snapshot(STARTUP_MAP_SNAPSHOT_PATH, list(payload = payload))
  invisible(TRUE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE if the startup map snapshot exists and is younger
# than max_age_seconds.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
startup_snapshot_fresh_enough <- function(max_age_seconds = STARTUP_SNAPSHOT_MAX_AGE_SECONDS) {
  !is.null(load_startup_map_snapshot(horizon_key = "live", primary_map = DEFAULT_PRIMARY_MAP, max_age_seconds = max_age_seconds))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE if a startup-warmer lock file exists and is younger
# than max_age_seconds (a sibling process is already warming).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
startup_warmer_active <- function(max_age_seconds = STARTUP_WARMER_MAX_AGE_SECONDS) {
  !is.null(load_runtime_snapshot(STARTUP_WARMER_LOCK_PATH, max_age_seconds = max_age_seconds))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Records a startup-warmer lock file (with pid + project_dir) so
# concurrent app starts do not all rebuild the snapshot.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
mark_startup_warmer_active <- function(project_dir = getwd()) {
  save_runtime_snapshot(
    STARTUP_WARMER_LOCK_PATH,
    list(
      pid = Sys.getpid(),
      project_dir = normalizePath(project_dir, winslash = "/", mustWork = FALSE)
    )
  )
  invisible(TRUE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Removes the startup-warmer lock file (no-op if absent) - call after
# the warmer finishes.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
clear_startup_warmer_active <- function() {
  if (file.exists(STARTUP_WARMER_LOCK_PATH)) unlink(STARTUP_WARMER_LOCK_PATH, force = TRUE)
  invisible(TRUE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns a sorted comma-separated key derived from
# compute_feature_requirements - used as the cache identity for an external
# bundle.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_feature_key <- function(selected_features = character(0), include_transport = FALSE) {
  requirements <- compute_feature_requirements(selected_features, include_transport = include_transport)
  features <- sort(unique(as.character(requirements$effective_features %||% character(0))))
  paste(c(features, if (isTRUE(include_transport)) ".transport" else character(0)), collapse = ",")
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Builds the in-memory cache key for an external bundle:
# "external-bundle-<horizon>-<hash(feature_key)>".
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_cache_name <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  feature_key <- external_bundle_feature_key(selected_features, include_transport = include_transport)
  paste0("external-bundle-", horizon_key, "-", cache_hash_string(feature_key))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the .rds snapshot path matching this external bundle's
# cache name - used for both load and save.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_snapshot_path <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  runtime_snapshot_file(sprintf("derived_%s", external_bundle_cache_name(horizon_key, selected_features, include_transport = include_transport)))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the lock file path used to detect "another process is
# warming this bundle" for the same (horizon, feature key).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_lock_path <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  runtime_snapshot_file(sprintf("external_bundle_lock_%s", external_bundle_cache_name(horizon_key, selected_features, include_transport = include_transport)))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the .log file path that warming workers tail-write progress
# into for the matching cache name.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_log_path <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  file.path(RUNTIME_CACHE_DIR, sprintf("external_bundle_%s.log", gsub("[^A-Za-z0-9._-]+", "_", external_bundle_cache_name(horizon_key, selected_features, include_transport = include_transport), perl = TRUE)))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the "fresh" TTL in seconds for the bundle:
# ALERT_TTL_SECONDS (>= 10min) for live, FORECAST_TTL_SECONDS for future.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_fresh_age_seconds <- function(horizon_key = "live") {
  if (identical(horizon_key %||% "live", "live")) max(10L * 60L, ALERT_TTL_SECONDS) else FORECAST_TTL_SECONDS
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the "stale-but-still-usable" TTL: 6h for live, 24h for
# future horizons - used when serving stale-while-revalidate.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_stale_age_seconds <- function(horizon_key = "live") {
  if (identical(horizon_key %||% "live", "live")) 6L * 3600L else 24L * 3600L
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the maximum mtime (in epoch seconds) across all
# external-bundle snapshot files - used to invalidate caches across feature
# combos.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
latest_external_bundle_snapshot_mtime <- function() {
  files <- list.files(RUNTIME_CACHE_DIR, pattern = "^derived_external-bundle-.*\\.rds$", full.names = TRUE)
  if (length(files) == 0) return(0)
  info <- file.info(files)
  mt <- safe_numeric(as.POSIXct(info$mtime, tz = "UTC"))
  mt <- mt[is.finite(mt)]
  if (length(mt) == 0) 0 else max(mt, na.rm = TRUE)
}

# Why: server reactives need a single cheap token that changes whenever the
# bundle snapshot or lock file changes, so they invalidate at the right time.
# What: returns a hex hash combining horizon, feature key, snapshot mtime,
# and lock mtime.
# How: stat the snapshot and lock paths, format mtimes as integers,
# concatenate, and run cache_hash_string.
# When: read every reactive tick by the bundle observer in server.R.
# Impact: a missed mtime change here causes the UI to keep showing stale
# bundle data until the next process restart.
external_bundle_cache_token <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  snap_path <- external_bundle_snapshot_path(horizon_key, selected_features, include_transport = include_transport)
  lock_path <- external_bundle_lock_path(horizon_key, selected_features, include_transport = include_transport)
  snap_mtime <- if (file.exists(snap_path)) safe_numeric(as.POSIXct(file.info(snap_path)$mtime, tz = "UTC")) else NA_real_
  lock_mtime <- if (file.exists(lock_path)) safe_numeric(as.POSIXct(file.info(lock_path)$mtime, tz = "UTC")) else NA_real_
  cache_hash_string(paste(
    horizon_key %||% "live",
    external_bundle_feature_key(selected_features, include_transport = include_transport),
    if (is.finite(snap_mtime)) format(round(snap_mtime, 0), scientific = FALSE) else "nosnap",
    if (is.finite(lock_mtime)) format(round(lock_mtime, 0), scientific = FALSE) else "nolock",
    sep = "|"
  ))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE if a warmer lock for this bundle exists and is
# younger than max_age_seconds (default 45 min).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_bundle_warmer_active <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE, max_age_seconds = 45L * 60L) {
  !is.null(load_runtime_snapshot(external_bundle_lock_path(horizon_key, selected_features, include_transport = include_transport), max_age_seconds = max_age_seconds))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Records a warmer lock file (pid, project_dir, feature_key,
# transport flag) for this bundle - sibling helper to
# mark_startup_warmer_active.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
mark_external_bundle_warmer_active <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE, project_dir = getwd()) {
  save_runtime_snapshot(
    external_bundle_lock_path(horizon_key, selected_features, include_transport = include_transport),
    list(
      pid = Sys.getpid(),
      project_dir = normalizePath(project_dir, winslash = "/", mustWork = FALSE),
      horizon_key = horizon_key,
      feature_key = external_bundle_feature_key(selected_features, include_transport = include_transport),
      include_transport = isTRUE(include_transport)
    )
  )
  invisible(TRUE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Removes the bundle's warmer lock file once warming is complete.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
clear_external_bundle_warmer_active <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  path <- external_bundle_lock_path(horizon_key, selected_features, include_transport = include_transport)
  if (file.exists(path)) unlink(path, force = TRUE)
  invisible(TRUE)
}

# Why: snapshots stored in older format are bare data.frames; newer ones are
# lists with completion metadata - we accept both shapes.
# What: returns a list(bundle, complete, completed_steps, total_steps,
# state) regardless of input shape, or NULL if value is unusable.
# How: if data.frame, wraps with complete=TRUE; if list with $bundle df,
# pulls fields with NA-safe coercions.
# When: called by load_external_bundle_snapshot wherever a snapshot is read.
# Impact: a future schema migration would extend this normaliser; keeping
# it tolerant prevents reads from crashing on old caches.
normalize_external_bundle_snapshot <- function(value = NULL) {
  if (is.null(value)) return(NULL)
  if (is.data.frame(value)) {
    return(list(
      bundle = value,
      complete = TRUE,
      completed_steps = NA_real_,
      total_steps = NA_real_,
      state = "complete"
    ))
  }
  if (!is.list(value) || !is.data.frame(value$bundle %||% NULL)) return(NULL)
  list(
    bundle = value$bundle,
    complete = isTRUE(value$complete),
    completed_steps = safe_numeric(value$completed_steps %||% NA_real_),
    total_steps = safe_numeric(value$total_steps %||% NA_real_),
    state = as.character(value$state %||% if (isTRUE(value$complete)) "complete" else "partial")
  )
}

# Why: downstream layers need this reference data in a known shape; loading
# it via a single helper centralises the path / version handling.
# What: Convenience: load_runtime_snapshot then
# normalize_external_bundle_snapshot.
# How: see body — short helper.
# When: called once at module-load time or on the first request that needs
# the reference data; cached for the rest of the session.
# Impact: invalidating the on-disk snapshot is the main lever for picking
# up updated reference data without restarting the session.
load_external_bundle_snapshot <- function(path, max_age_seconds = Inf) {
  normalize_external_bundle_snapshot(load_runtime_snapshot(path, max_age_seconds = max_age_seconds))
}

# Why: a downstream session needs the value persisted so the next process
# can warm-start instead of recomputing from scratch.
# What: Persists a bundle data.frame plus completion metadata so partial
# bundles can be resumed and complete ones served from disk.
# How: cache lookup + put.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
save_external_bundle_snapshot <- function(path, bundle = data.frame(), complete = TRUE, completed_steps = NA_real_, total_steps = NA_real_, state = NULL) {
  save_runtime_snapshot(
    path,
    list(
      bundle = as.data.frame(bundle),
      complete = isTRUE(complete),
      completed_steps = safe_numeric(completed_steps %||% NA_real_),
      total_steps = safe_numeric(total_steps %||% NA_real_),
      state = as.character(state %||% if (isTRUE(complete)) "complete" else "partial")
    )
  )
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Lists all "derived_external-bundle-live-*.rds" files in
# RUNTIME_CACHE_DIR for fallback search.
# How: cache lookup + put.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
list_live_external_bundle_snapshot_paths <- function() {
  list.files(RUNTIME_CACHE_DIR, pattern = "^derived_external-bundle-live-.*\\.rds$", full.names = TRUE)
}

# Why: cold-start the live external bundle by trying memory cache, then the
# exact-feature snapshot, then any other live bundle on disk.
# What: returns the cached/loaded bundle data.frame, or NULL if nothing
# usable was found.
# How: probes cache_get -> exact path snapshot -> sorted list of fallback
# paths newest-first; first hit wins.
# When: called early at startup so we can paint a passable map before the
# warmer rebuilds the exact-feature bundle.
# Impact: a cross-feature fallback may show data slightly off-target, but
# beats showing nothing while the warmer runs.
load_live_external_support_bundle <- function(selected_features = FAST_START_FEATURES, include_transport = FALSE, max_age_seconds = external_bundle_stale_age_seconds("live")) {
  cache_name <- external_bundle_cache_name("live", selected_features, include_transport = include_transport)
  cached <- cache_get("derived", cache_name)
  if (is.data.frame(cached) && nrow(cached) > 0) return(cached)

  exact_path <- external_bundle_snapshot_path("live", selected_features, include_transport = include_transport)
  exact_info <- load_external_bundle_snapshot(exact_path, max_age_seconds = max_age_seconds)
  if (!is.null(exact_info$bundle) && is.data.frame(exact_info$bundle) && nrow(exact_info$bundle) > 0) {
    cache_put("derived", cache_name, exact_info$bundle, ttl_seconds = max(60L, min(external_bundle_fresh_age_seconds("live"), max_age_seconds)))
    return(exact_info$bundle)
  }

  fallback_paths <- setdiff(list_live_external_bundle_snapshot_paths(), exact_path)
  if (!length(fallback_paths)) return(NULL)
  info <- file.info(fallback_paths)
  ord <- order(info$mtime, decreasing = TRUE, na.last = NA)
  for (path in fallback_paths[ord]) {
    snap <- load_external_bundle_snapshot(path, max_age_seconds = max_age_seconds)
    if (!is.null(snap$bundle) && is.data.frame(snap$bundle) && nrow(snap$bundle) > 0) {
      return(snap$bundle)
    }
  }
  NULL
}

# Why: downstream callers need this lookup encapsulated so cache + fallback
# handling lives in one place.
# What: Returns the cached zipcode->place_name vector, or a NA-filled
# fallback when the lookup hasn't been populated yet.
# How: cache lookup + put + named vector build.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
get_cached_zip_place_lookup <- function() {
  cached <- cache_get("derived", "zip_place_lookup")
  if (!is.null(cached)) return(cached)
  setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
}

# Why: a fresh zip->place lookup invalidates derived per-zip displays that
# embedded the old place names.
# What: returns the freshly built lookup and signals readiness via cache;
# also clears stale forecast/risk/view-state caches.
# How: calls load_zip_place_lookup, invalidates "derived" prefixes for
# forecast-baseline / risk / view-state, sets zip_place_lookup_ready flag.
# When: invoked once at startup after place data is available.
# Impact: failing to invalidate the right prefixes here leaves "N/A" cities
# in popups; running too eagerly causes a cold rebuild of all per-zip data.
warm_zip_place_lookup <- function() {
  lookup <- load_zip_place_lookup()
  invalidate_cache_prefix("derived", "forecast-baseline-")
  invalidate_cache_prefix("derived", "risk-")
  invalidate_cache_prefix("derived", "view-state-")
  cache_put("derived", "zip_place_lookup_ready", TRUE, ttl_seconds = 24 * 3600)
  lookup
}
