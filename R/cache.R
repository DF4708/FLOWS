# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/cache.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: cache keys can be unbounded (full URLs, long signatures) but R env names
# perform poorly on huge keys, so we collapse them with a short hash.
# What: returns a 16-char hex digest derived from x, used as a stable suffix
# when the original key exceeds the byte limit.
# How: dual rolling-hash over UTF-8 code points using two large primes, packed
# into two 8-char hex words.
# When: invoked only by cache_key when key length crosses MAX_CACHE_KEY_BYTES.
# Impact: collisions would cause two different cache entries to clobber each
# other; the dual-hash design keeps the practical collision probability tiny.
cache_hash_string <- function(x) {
  txt <- enc2utf8(safe_string(x))
  bytes <- utf8ToInt(txt)
  if (length(bytes) == 0) return("0000000000000000")
  h1 <- 0
  h2 <- 0
  for (b in bytes) {
    h1 <- (h1 * 131 + b) %% 2147483647
    h2 <- (h2 * 65599 + b) %% 2147483629
  }
  sprintf("%08x%08x", as.integer(h1), as.integer(h2))
}

# Why: every cache lookup needs a namespaced, length-bounded string suitable
# for use as an environment name in live_cache.
# What: returns "<namespace>::<key>" where overlong keys are truncated and
# suffixed with a hash to stay reversible-ish but fixed in size.
# How: collapses vector keys with "|", checks byte length, replaces the tail
# with a cache_hash_string suffix when it exceeds MAX_CACHE_KEY_BYTES.
# When: called by every cache_get/cache_put/invalidate_* helper before
# touching live_cache.
# Impact: changing the encoding here invalidates all in-memory cache entries
# (a fresh prefix means lookups miss and force re-fetch).
cache_key <- function(namespace, key) {
  key_txt <- safe_string(key)
  if (length(key_txt) > 1) key_txt <- paste(key_txt, collapse = "|")
  key_bytes <- nchar(key_txt, type = "bytes")
  if (!is.finite(key_bytes)) key_bytes <- nchar(enc2utf8(key_txt), type = "bytes")
  if (is.finite(key_bytes) && key_bytes > MAX_CACHE_KEY_BYTES) {
    key_txt <- paste0(
      substr(key_txt, 1, MAX_CACHE_KEY_PREFIX_CHARS),
      "..",
      cache_hash_string(key_txt)
    )
  }
  paste(namespace, key_txt, sep = "::")
}

# Why: each namespace has a soft per-namespace size cap (namespace_limits) so
# long-running sessions do not balloon memory.
# What: invisibly returns TRUE; side-effect drops the oldest entries until the
# namespace's count is at or under its limit.
# How: lists keys with the "<namespace>::" prefix, reads $created_at off each
# entry, sorts ascending and rms the excess.
# When: called from cache_put right after every insertion.
# Impact: a wrong limit causes either OOM (too high) or thrashing re-fetches
# (too low); LRU here is "oldest-creation", not last-access.
prune_cache_namespace <- function(namespace) {
  limit <- namespace_limits[[namespace]] %||% NA_integer_
  if (!is.finite(limit)) return(invisible(TRUE))
  ns_keys <- ls(envir = live_cache, all.names = TRUE)
  ns_keys <- ns_keys[startsWith(ns_keys, paste0(namespace, "::"))]
  if (length(ns_keys) <= limit) return(invisible(TRUE))
  created <- vapply(
    ns_keys,
    function(k) {
      item <- live_cache[[k]]
      as.numeric(item$created_at %||% as.POSIXct(0, origin = "1970-01-01", tz = "UTC"))
    },
    numeric(1)
  )
  drop_keys <- ns_keys[order(created)][seq_len(length(ns_keys) - limit)]
  rm(list = drop_keys, envir = live_cache)
  invisible(TRUE)
}

# Why: standard write path - every cached value needs created_at and an
# expires_at so cache_get can lazily evict on read.
# What: stores the value under cache_key(namespace, key) in live_cache and
# returns the value invisibly.
# How: builds a list(value, created_at, expires_at) and immediately calls
# prune_cache_namespace to enforce the size cap.
# When: called by every loader and derivation that needs to memoise across
# reactive ticks.
# Impact: a missing prune call here would let any namespace grow unbounded;
# a wrong TTL silently makes data either stale or refetched too often.
cache_put <- function(namespace, key, value, ttl_seconds) {
  live_cache[[cache_key(namespace, key)]] <- list(
    value = value,
    created_at = Sys.time(),
    expires_at = Sys.time() + ttl_seconds
  )
  prune_cache_namespace(namespace)
  invisible(value)
}

# Why: the standard read path enforces TTL eviction lazily so callers do not
# need to track expiry themselves.
# What: returns the cached value, or NULL when the key is absent or expired
# (with the expired entry removed as a side-effect).
# How: looks up via exists(), checks expires_at against Sys.time(), and rms
# the entry if it has aged out.
# When: invoked at the top of any data loader to short-circuit a network call
# when fresh data is in memory.
# Impact: returning NULL forces the caller to refetch; broken TTL logic here
# pins stale data on the map indefinitely.
cache_get <- function(namespace, key) {
  ck <- cache_key(namespace, key)
  if (!exists(ck, envir = live_cache, inherits = FALSE)) return(NULL)
  item <- live_cache[[ck]]
  if (!is.null(item$expires_at) && Sys.time() > item$expires_at) {
    rm(list = ck, envir = live_cache)
    return(NULL)
  }
  item$value
}

# Like cache_get but ignores expires_at and never evicts - lets callers serve stale data while a refetch is in flight.
cache_peek <- function(namespace, key) {
  ck <- cache_key(namespace, key)
  if (!exists(ck, envir = live_cache, inherits = FALSE)) return(NULL)
  item <- live_cache[[ck]]
  item$value
}

# Why: warm-start the app from disk so the first user does not wait on every
# reference dataset to refetch.
# What: returns the saved $value if the snapshot file exists and is younger
# than max_age_seconds, else NULL.
# How: readRDS the file, extracts saved_at, computes age in seconds, returns
# value only when age is finite and within the bound.
# When: called once on startup by global.R for each pre-baked snapshot.
# Impact: a stale or corrupt snapshot returning bad data would surface across
# the whole UI; the age guard is the only protection against that.
load_runtime_snapshot <- function(path, max_age_seconds = Inf) {
  if (!file.exists(path)) return(NULL)
  snap <- safely(readRDS(path))
  if (is.null(snap) || is.null(snap$saved_at)) return(NULL)
  snap_age <- safe_numeric(difftime(Sys.time(), as.POSIXct(snap$saved_at, tz = "UTC"), units = "secs"))
  if (!is.finite(snap_age) || snap_age < 0 || snap_age > max_age_seconds) return(NULL)
  snap$value
}

# Persists value to path with a saved_at marker so load_runtime_snapshot can later check freshness; never throws.
save_runtime_snapshot <- function(path, value) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  snap <- list(saved_at = Sys.time(), value = value)
  safely(saveRDS(snap, path, compress = FALSE))
  invisible(TRUE)
}

# Returns the canonical .rds path under RUNTIME_CACHE_DIR for a named snapshot, sanitising the name to filesystem-safe chars.
runtime_snapshot_file <- function(name) {
  safe_name <- gsub("[^A-Za-z0-9._-]+", "_", as.character(name %||% "snapshot"), perl = TRUE)
  file.path(RUNTIME_CACHE_DIR, paste0(safe_name, ".rds"))
}

# Why: TTL eviction in cache_get is lazy, so long-idle keys can occupy memory
# even after expiry; this sweep reclaims them.
# What: invisibly returns TRUE; removes every live_cache entry whose
# expires_at is in the past or missing.
# How: scans all keys, builds a logical mask of expired items, and rms the
# matching set in one batch.
# When: called by release_runtime_memory and the periodic memory-pressure
# observer in server.R.
# Impact: too-aggressive a purge invalidates fresh-but-aging entries; never
# calling it causes slow memory creep.
purge_expired_live_cache <- function() {
  keys <- ls(envir = live_cache, all.names = TRUE)
  if (length(keys) == 0) return(invisible(TRUE))
  expired <- vapply(
    keys,
    function(k) {
      item <- live_cache[[k]]
      is.null(item) || is.null(item$expires_at) || Sys.time() > item$expires_at
    },
    logical(1)
  )
  if (any(expired)) rm(list = keys[expired], envir = live_cache)
  invisible(TRUE)
}

# Drops every live_cache entry whose key starts with "<namespace>::<prefix>"; used to bulk-invalidate a category of derived data.
invalidate_cache_prefix <- function(namespace, prefix = "") {
  keys <- ls(envir = live_cache, all.names = TRUE)
  full_prefix <- paste0(namespace, "::", prefix)
  keys <- keys[startsWith(keys, full_prefix)]
  if (length(keys) > 0) rm(list = keys, envir = live_cache)
  invisible(TRUE)
}

# Returns the single most-recently created cache key from a candidate list, or character(0) if none have created_at set.
latest_live_cache_key <- function(keys) {
  keys <- as.character(keys %||% character(0))
  if (length(keys) == 0) return(character(0))
  created <- vapply(
    keys,
    function(k) {
      item <- live_cache[[k]]
      as.numeric(item$created_at %||% as.POSIXct(0, origin = "1970-01-01", tz = "UTC"))
    },
    numeric(1)
  )
  keys[order(created, decreasing = TRUE)][1]
}

# Why: derived map artefacts (risk, view-state, road overlay, route segments)
# are keyed by horizon and primary map, and stale (horizon,primary) combos
# are dead weight after the user changes selection.
# What: invisibly returns TRUE; removes every "derived::*" entry not tied to
# the currently-selected horizon/primary, retaining only the latest of each
# active category.
# How: collects keys per category, picks the newest of each via
# latest_live_cache_key, and rms the rest of the derived prefix space.
# When: triggered after horizon/primary toggles and from the periodic
# memory-pressure observer in server.R.
# Impact: a misaligned primary_tag drops the live map artefacts and forces a
# costly redraw; the keep-latest design preserves smooth interactivity.
purge_inactive_map_caches <- function(current_horizon = "live", current_primary = DEFAULT_PRIMARY_MAP) {
  current_horizon <- as.character(current_horizon %||% "live")
  current_primary <- normalize_primary_map(current_primary)
  keys <- ls(envir = live_cache, all.names = TRUE)
  if (length(keys) == 0) return(invisible(TRUE))

  primary_tag <- sprintf(".primary:%s", current_primary)
  current_risk_keys <- keys[
    startsWith(keys, paste0("derived::risk-", current_horizon, "-")) &
      grepl(primary_tag, keys, fixed = TRUE)
  ]
  current_view_keys <- keys[
    startsWith(keys, paste0("derived::view-state-", current_horizon, "-")) &
      grepl(primary_tag, keys, fixed = TRUE)
  ]
  current_road_keys <- keys[startsWith(keys, paste0("derived::roads-overlay-", current_horizon))]
  current_route_segment_keys <- keys[startsWith(keys, paste0("derived::route-segments-", current_horizon, "-"))]

  keep_keys <- unique(c(
    latest_live_cache_key(current_risk_keys),
    latest_live_cache_key(current_view_keys),
    latest_live_cache_key(current_road_keys),
    latest_live_cache_key(current_route_segment_keys)
  ))
  keep_keys <- keep_keys[nzchar(keep_keys)]

  drop_keys <- keys[
    startsWith(keys, "derived::risk-") |
      startsWith(keys, "derived::view-state-") |
      startsWith(keys, "derived::roads-overlay-") |
      startsWith(keys, "derived::route-segments-")
  ]
  drop_keys <- setdiff(drop_keys, keep_keys)
  if (length(drop_keys) > 0) rm(list = drop_keys, envir = live_cache)
  invisible(TRUE)
}

# Convenience: purge expired cache entries and trigger a (full=TRUE optional) gc to free OS-level memory back.
release_runtime_memory <- function(full = FALSE) {
  purge_expired_live_cache()
  invisible(gc(verbose = FALSE, full = isTRUE(full)))
}

# Why: when a new derivation replaces an old one under a shared prefix, the
# old siblings remain in cache and waste memory.
# What: invisibly returns TRUE; rms every entry under "<namespace>::<prefix>"
# except the one named in keep_key.
# How: lists matching keys, computes the keep_key's full id via cache_key,
# subtracts it from the drop set, and rms the remainder.
# When: called by builders that promote a single new artefact to "current"
# and want to retire all earlier variants.
# Impact: skipping this leaks per-version cache entries; passing the wrong
# keep_key drops the live artefact and forces a rebuild.
invalidate_replaced_live_payloads <- function(namespace = "derived", prefix = "", keep_key = NULL) {
  prefix <- safe_string(prefix)
  if (!nzchar(prefix)) return(invisible(TRUE))
  keys <- ls(envir = live_cache, all.names = TRUE)
  full_prefix <- paste0(namespace, "::", prefix)
  drop_keys <- keys[startsWith(keys, full_prefix)]
  if (!is.null(keep_key) && nzchar(safe_string(keep_key))) {
    drop_keys <- setdiff(drop_keys, cache_key(namespace, keep_key))
  }
  if (length(drop_keys) > 0) rm(list = drop_keys, envir = live_cache)
  invisible(TRUE)
}

# Why: ZIP rendering streams tiles north-to-south so the first paint covers
# the user's likely viewport faster.
# What: returns the unique latitude band ids present in zips, sorted in the
# requested direction (default descending = north first).
# How: coerces lat_band to integer, drops non-finite, and unique-sorts.
# When: paired with latitude_band_row_groups during streamed rendering of
# the ZIP polygon layer.
# Impact: an empty result collapses the streaming order to a single batch,
# undoing the perceived-performance optimisation.
ordered_latitude_bands_for_zips <- function(zips, descending = TRUE) {
  if (is.null(zips) || nrow(zips) == 0 || !"lat_band" %in% names(zips)) return(integer(0))
  bands <- suppressWarnings(as.integer(zips$lat_band))
  bands <- bands[is.finite(bands)]
  if (length(bands) == 0) return(integer(0))
  sort(unique(bands), decreasing = isTRUE(descending))
}

# Why: the streaming renderer needs row indices grouped by latitude band so it
# can batch addPolygons calls per band.
# What: returns a list of integer index vectors, one per band, in the order
# given by ordered_latitude_bands_for_zips.
# How: maps each band id to which() of zips$lat_band == that id; falls back
# to a single group of all rows if no bands exist.
# When: called immediately before a sequence of leafletProxy redraws when
# the ZIP layer is being painted progressively.
# Impact: a missing band id silently drops those ZIPs from the render,
# leaving holes on the map.
latitude_band_row_groups <- function(zips, descending = TRUE) {
  bands <- ordered_latitude_bands_for_zips(zips, descending = descending)
  if (length(bands) == 0) return(list(seq_len(nrow(zips))))
  lapply(
    bands,
    function(band_id) which(suppressWarnings(as.integer(zips$lat_band)) == band_id)
  )
}

# Returns the canonical list of ZIP-view columns used by zip_view_changed_rows for diff-based incremental rendering.
zip_view_compare_columns <- function() {
  c(
    "place_name", "horizon_label", "risk_label", "alert_event", "alert_url", "alert_event_list", "alert_url_list", "forecast_short", "seismic_event_text", "radiation_reason_text", "nrc_event_text",
    "proximity_boosted", "county_name", "forecast_temperature_f", "forecast_wind_mph", "forecast_wind_dir", "forecast_pop_pct",
    "annual_avg_temperature_f", "apparent_temperature_f", "temperature_pressure_f", "temperature_pressure_text",
    "normalized_risk_score", "fill_risk_score", "display_risk_label", "risk_fill_rgba", "risk_reason_text", "risk_component_summary_text", "risk_type_summary_text",
    "flood_total_score", "winter_total_score", "convective_total_score", "fire_total_score", "wind_total_score",
    "heat_total_score", "cold_total_score", "air_total_score", "radiation_total_score", "seismic_total_score",
    "heatrisk_official_score", "airnow_total_score", "convective_guidance_score", "nwm_flood_outlook_score",
    "driving_total_risk", "driving_risk_label", "driving_reason_text"
  )
}

# Why: instead of redrawing every ZIP polygon on each tick, we only update
# rows whose attributes actually changed.
# What: returns a logical vector of length nrow(current_df) marking which
# rows differ from previous_df across compare_cols.
# How: column-by-column compare with NA-safe logic; numeric columns compare
# with abs-diff > 1e-9, character columns compare via NA-coerced strings.
# When: server.R calls this after recomputing the live ZIP frame, to drive
# a partial leafletProxy redraw.
# Impact: a missed column produces visible "stuck" cells; a too-strict
# compare causes whole-layer redraws and lag.
zip_view_changed_rows <- function(current_df, previous_df, compare_cols = zip_view_compare_columns()) {
  if (is.null(previous_df) || nrow(previous_df) != nrow(current_df)) return(rep(TRUE, nrow(current_df)))
  changed <- rep(FALSE, nrow(current_df))
  for (col in compare_cols) {
    oldv <- if (col %in% names(previous_df)) previous_df[[col]] else rep(NA, nrow(previous_df))
    newv <- if (col %in% names(current_df)) current_df[[col]] else rep(NA, nrow(current_df))
    neq <- if (is.numeric(newv)) {
      old_num <- safe_numeric(oldv)
      new_num <- safe_numeric(newv)
      old_num[!is.finite(old_num)] <- 0
      new_num[!is.finite(new_num)] <- 0
      (is.na(oldv) != is.na(newv)) | (abs(old_num - new_num) > 1e-9)
    } else {
      ifelse(is.na(oldv), "", as.character(oldv)) != ifelse(is.na(newv), "", as.character(newv))
    }
    changed <- changed | neq
  }
  changed
}
