# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/nwps.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: NWPS stage/flow JSON nests numeric values arbitrarily deep; we want
# a flat (path, value) table to scan for the right field.
# What: returns a data.frame(path, value) where path is a "/"-joined dot
# path through the JSON and value is the first finite numeric.
# How: recurses through lists, tracking the path; emits one row per leaf
# numeric (or numeric-looking string).
# When: helper for extract_stageflow_components when reading NWPS payloads.
# Impact: a deeply pathological structure produces many rows but never
# crashes; the path strings are the only handle for downstream filters.
flatten_numeric_paths <- function(obj, prefix = "") {
  rows <- list()
  recurse <- function(x, path_so_far) {
    if (is.null(x)) return(NULL)
    if (is.list(x) && !is.data.frame(x)) {
      nms <- names(x)
      for (i in seq_along(x)) {
        nm <- nms[[i]] %||% as.character(i)
        next_path <- if (nzchar(path_so_far)) paste(path_so_far, nm, sep = "/") else nm
        recurse(x[[i]], next_path)
      }
      return(NULL)
    }
    vals <- safe_numeric(as.character(x))
    vals <- vals[is.finite(vals)]
    if (length(vals) == 0) return(NULL)
    rows[[length(rows) + 1L]] <<- data.frame(path = if (nzchar(path_so_far)) path_so_far else "value", value = vals[[1]], stringsAsFactors = FALSE)
    invisible(NULL)
  }
  recurse(obj, prefix)
  if (length(rows) == 0) return(data.frame(path = character(), value = numeric(), stringsAsFactors = FALSE))
  dplyr::bind_rows(rows)
}

# Why: NWPS payloads bundle observed/forecast/NWM values in inconsistent
# field names; we need the three components separately for scoring.
# What: returns list(observed, forecast, nwm) of numeric values (or NA when
# no path matched).
# How: flattens the payload, filters paths to stage/flow/streamflow/etc.
# minus thresholds, then runs include/exclude regex filters per component.
# When: called by extract_stageflow_signal and the gauge ingest pipeline.
# Impact: a missing keyword silently zeros a component; the include/exclude
# patterns are the maintenance hot spot when NWPS adds new path keys.
extract_stageflow_components <- function(stage_payload) {
  flat <- flatten_numeric_paths(stage_payload)
  if (nrow(flat) == 0) {
    return(list(observed = NA_real_, forecast = NA_real_, nwm = NA_real_))
  }
  keep <- grepl("stage|flow|value|streamflow|discharge|crest", flat$path, ignore.case = TRUE) &
    !grepl("action|minor|moderate|major|record|latitude|longitude|datum|time|date|year|month|day|threshold|category|trend|departure|percentile|interval|probability|units", flat$path, ignore.case = TRUE)
  if (!any(keep)) {
    return(list(observed = NA_real_, forecast = NA_real_, nwm = NA_real_))
  }
  kept <- flat[keep, , drop = FALSE]
  kept$path_lc <- tolower(kept$path)
  pull_best <- function(include_pattern, exclude_pattern = NULL) {
    idx <- grepl(include_pattern, kept$path_lc, perl = TRUE)
    if (!is.null(exclude_pattern)) {
      idx <- idx & !grepl(exclude_pattern, kept$path_lc, perl = TRUE)
    }
    vals <- kept$value[idx]
    vals <- vals[is.finite(vals)]
    if (length(vals) == 0) return(NA_real_)
    max(vals, na.rm = TRUE)
  }
  observed <- pull_best("observ|current|latest|primary|analysis", "forecast|crest|max|future|nwm|national.?water.?model|short.?range|medium.?range|open.?loop|member")
  forecast <- pull_best("forecast|crest|max|future|fcst", "nwm|national.?water.?model|short.?range|medium.?range|open.?loop|member")
  nwm <- pull_best("nwm|national.?water.?model|short.?range|medium.?range|open.?loop|analysis.?assim|member")
  if (!is.finite(observed)) observed <- pull_best("stage|flow|streamflow|discharge", "forecast|crest|max|future|nwm|national.?water.?model")
  if (!is.finite(forecast)) forecast <- pull_best("stage|flow|streamflow|discharge|crest", "nwm|national.?water.?model")
  list(observed = observed, forecast = forecast, nwm = nwm)
}

# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns max(observed, forecast, nwm) from the stage payload as a
# single scalar, NA if all components are missing.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_stageflow_signal <- function(stage_payload) {
  comps <- extract_stageflow_components(stage_payload)
  vals <- c(comps$observed, comps$forecast, comps$nwm)
  vals <- vals[is.finite(vals)]
  if (length(vals) == 0) return(NA_real_)
  max(vals, na.rm = TRUE)
}

# Why: NWPS publishes per-gauge action/flood/moderate/major thresholds; we
# need a scoring function that handles missing thresholds gracefully.
# What: returns a 0..1 score by piecewise_score(value, action, flood,
# major), defaulting missing thresholds from neighbours.
# How: backfills NA thresholds in priority order (use neighbour's value
# when missing) so a partial gauge still scores.
# When: called per gauge in the NWPS context build to assign observed/
# forecast/NWM scores.
# Impact: gauges with only one threshold reported still produce sensible
# scores; missing all thresholds collapses to 0.
score_stageflow_against_thresholds <- function(value, action = NA_real_, flood = NA_real_, moderate = NA_real_, major = NA_real_) {
  if (!is.finite(value)) return(0)
  thresholds <- c(action = action, flood = flood, moderate = moderate, major = major)
  finite_thresholds <- thresholds[is.finite(thresholds)]
  if (length(finite_thresholds) == 0) return(0)
  a <- thresholds[["action"]]
  if (!is.finite(a)) a <- min(finite_thresholds)
  f <- thresholds[["flood"]]
  if (!is.finite(f)) f <- if (length(finite_thresholds) >= 2) sort(finite_thresholds)[2] else a
  m <- thresholds[["moderate"]]
  if (!is.finite(m)) m <- max(f, max(finite_thresholds))
  g <- thresholds[["major"]]
  if (!is.finite(g)) g <- max(m, max(finite_thresholds))
  piecewise_score(value, a, f, g)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the human band label ("major flood stage", "moderate flood
# stage", "flood stage", "action stage", "elevated water conditions") for a
# stage value.
# How: sf geometry op + named vector build.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
stageflow_band_label <- function(value, action = NA_real_, flood = NA_real_, moderate = NA_real_, major = NA_real_) {
  if (!is.finite(value)) return("elevated water conditions")
  if (is.finite(major) && value >= major) return("major flood stage")
  if (is.finite(moderate) && value >= moderate) return("moderate flood stage")
  if (is.finite(flood) && value >= flood) return("flood stage")
  if (is.finite(action) && value >= action) return("action stage")
  "elevated water conditions"
}

# Why: a downstream consumer needs the assembled output in a single call
# rather than calling the underlying primitives separately.
# What: Returns the popup-ready reason text describing the gauge's dominant
# signal source ("observed/forecast/NWM") and its band label.
# How: sf geometry op + named vector build.
# When: called by the layer's top-level builder when assembling the
# user-visible output.
# Impact: any new column or row source needs to be added here AND in the
# layer's standardise_* schema; mismatched schemas show up as silent column
# drops downstream.
build_stageflow_reason_text <- function(gauge_id, dominant_source, dominant_value, action = NA_real_, flood = NA_real_, moderate = NA_real_, major = NA_real_) {
  if (!is.finite(dominant_value)) return(NA_character_)
  band <- stageflow_band_label(dominant_value, action = action, flood = flood, moderate = moderate, major = major)
  gauge_txt <- if (is_nontrivial_string(gauge_id)) sprintf(" at gauge %s", as.character(gauge_id)) else ""
  if (identical(dominant_source, "nwm")) {
    sprintf("NWPS National Water Model guidance%s indicates %s.", gauge_txt, band)
  } else if (identical(dominant_source, "forecast")) {
    sprintf("NWPS forecast river conditions%s indicate %s.", gauge_txt, band)
  } else {
    sprintf("NWPS observed river conditions%s indicate %s.", gauge_txt, band)
  }
}

# Why: the canonical empty shape is needed wherever the upstream feed is
# missing or fails so downstream rbind / merge calls don't break the
# schema.
# What: Returns the canonical empty NWPS context (zero/NA per ZCTA, empty
# gauge sf) used when fetch_nwps_gauge_context fails or returns no gauges.
# How: sf geometry op + named vector build.
# When: called as the fallback in every fetcher / compute step when the
# upstream feed is missing or returns no rows.
# Impact: changing the column set requires a matching update in every
# fetcher / compute step that returns this empty shape on failure.
empty_nwps_context <- function() {
  named_zero <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  named_na <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  empty_sf <- sf::st_sf(
    gauge_id = character(0),
    action = numeric(0),
    flood = numeric(0),
    moderate = numeric(0),
    major = numeric(0),
    observed_score = numeric(0),
    forecast_score = numeric(0),
    nwm_score = numeric(0),
    observed_label = character(0),
    forecast_label = character(0),
    nwm_label = character(0),
    geometry = sf::st_sfc(crs = 4326)
  )
  list(
    scores = named_zero,
    labels = named_na,
    dominant_source = named_na,
    observed_scores = named_zero,
    forecast_scores = named_zero,
    nwm_scores = named_zero,
    observed_labels = named_na,
    forecast_labels = named_na,
    nwm_labels = named_na,
    gauge_sf = empty_sf
  )
}

# Why: produce a single per-ZIP river-context structure with separate
# observed/forecast/NWM scores so the downstream selector can pick the
# right one per horizon.
# What: returns a list with per-zip score/label vectors (named by zipcode)
# for each of observed/forecast/NWM plus a gauge_sf with thresholds and
# scores - all cached in memory and on-disk for ~15-45 minutes.
# How: pulls the gauge inventory, fetches stage payload per gauge, runs
# extract_stageflow_components and score_stageflow_against_thresholds,
# then snaps to nearest ZIP via st_nearest_feature.
# When: called by compute_nwps_corridor_signal at the top of the flood
# pipeline.
# Impact: this is the single most expensive flood data path - cache misses
# trigger many NWPS API calls; partial gauges get partial scoring.
fetch_nwps_gauge_context <- function() {
  key <- "nwps-gauge-context"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", key))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = 45 * 60)
  if (!is.null(persisted)) {
    cache_put("derived", key, persisted, ttl_seconds = 15 * 60)
    return(persisted)
  }
  # Cold fetch re-enabled (was previously gated off because per-gauge stage
  # fetches were sequential and could block 100+ s on a fresh cache). The
  # per-gauge loop below now runs through parallel::mclapply, capping cold
  # latency at one batch * timeout. The initial bbox query is a single fast
  # call that returns gauge metadata only.
  # The NWPS gauges endpoint silently returns an empty list if `srid` is not
  # supplied - the default coordinate system is unspecified and rejects the
  # signed lon/lat we pass. Adding srid=EPSG_4326 makes WGS84 explicit.
  url <- sprintf(
    "%s?bbox.xmin=%s&bbox.ymin=%s&bbox.xmax=%s&bbox.ymax=%s&srid=EPSG_4326",
    NWPS_GAUGES_URL,
    utils::URLencode(as.character(wi_bounds$west),  reserved = TRUE),
    utils::URLencode(as.character(wi_bounds$south), reserved = TRUE),
    utils::URLencode(as.character(wi_bounds$east),  reserved = TRUE),
    utils::URLencode(as.character(wi_bounds$north), reserved = TRUE)
  )
  payload <- safely(http_json(url, timeout_seconds = 8L, max_tries = 2L))
  if (is.null(payload)) {
    out <- empty_nwps_context()
    cache_put("derived", key, out, ttl_seconds = 900)
    return(out)
  }
  items <- payload$items %||% payload$gauges %||% payload$data %||% payload
  if (!is.list(items) || length(items) == 0) {
    out <- empty_nwps_context()
    cache_put("derived", key, out, ttl_seconds = 900)
    return(out)
  }
  get_num <- function(obj, keys) {
    for (k in keys) {
      if (!is.null(obj[[k]])) {
        v <- safe_numeric(obj[[k]])
        if (is.finite(v)) return(v)
      }
    }
    NA_real_
  }
  gauge_rows <- lapply(items, function(it) {
    lat <- get_num(it, c("latitude", "lat", "y"))
    lon <- get_num(it, c("longitude", "lon", "x"))
    id <- as.character(it$lid %||% it$identifier %||% it$id %||% NA_character_)
    if (!is.finite(lat) || !is.finite(lon) || is.na(id)) return(NULL)
    list(id = id, lon = lon, lat = lat,
         action = get_num(it, c("actionStage", "action", "actionFlow")),
         flood = get_num(it, c("floodStage", "flood", "minorStage")),
         moderate = get_num(it, c("moderateStage", "moderate")),
         major = get_num(it, c("majorStage", "major")))
  })
  gauge_rows <- Filter(Negate(is.null), gauge_rows)
  if (length(gauge_rows) == 0) {
    out <- empty_nwps_context()
    cache_put("derived", key, out, ttl_seconds = 900)
    return(out)
  }
  gauges_df <- dplyr::bind_rows(lapply(gauge_rows, as.data.frame))
  gauges_sf <- sf::st_as_sf(gauges_df, coords = c("lon", "lat"), crs = 4326)
  observed_scores <- rep(0, nrow(gauges_sf))
  forecast_scores <- rep(0, nrow(gauges_sf))
  nwm_scores <- rep(0, nrow(gauges_sf))
  observed_labels <- rep(NA_character_, nrow(gauges_sf))
  forecast_labels <- rep(NA_character_, nrow(gauges_sf))
  nwm_labels <- rep(NA_character_, nrow(gauges_sf))
  live_scores <- rep(0, nrow(gauges_sf))
  live_labels <- rep(NA_character_, nrow(gauges_sf))
  live_sources <- rep(NA_character_, nrow(gauges_sf))
  # Parallel per-gauge stage fetch. Each call is independent I/O; mclapply
  # forks workers on macOS / Linux (the only Shiny deploy targets). Falls
  # back to sequential lapply on Windows where mc.cores must equal 1.
  fetch_one <- function(i) {
    id <- gauges_df$id[i]
    stage_url <- sprintf("%s/%s/stageflow", NWPS_GAUGES_URL, id)
    # 4 s timeout (was 6). Healthy NWPS stage responses arrive in
    # <1.5 s; the long tail is hung gauges. Failing fast gives the
    # mclapply pool more time to drain the rest of the queue without
    # blocking on stragglers.
    stage_payload <- tryCatch(http_json(stage_url, timeout_seconds = 4L, max_tries = 1L),
                              error = function(e) NULL)
    if (is.null(stage_payload)) {
      return(list(observed = NA_real_, forecast = NA_real_, nwm = NA_real_))
    }
    extract_stageflow_components(stage_payload)
  }
  n_gauges <- nrow(gauges_sf)
  # Per-gauge fetches are pure network I/O. The WI bbox returns ~455
  # gauges, so 12 cores * 6 s timeout = 76 s worst case; doubling to 24
  # cores at 4 s timeout caps worst case at ~76 s but typical drops to
  # ~15-25 s. NWPS handles the higher concurrency without throttling at
  # this volume. CPU cost is negligible — each worker waits on I/O.
  mc_cores <- if (.Platform$OS.type == "windows") 1L else min(24L, max(1L, n_gauges))
  comps_list <- if (mc_cores > 1L) {
    parallel::mclapply(seq_len(n_gauges), fetch_one, mc.cores = mc_cores, mc.preschedule = FALSE)
  } else {
    lapply(seq_len(n_gauges), fetch_one)
  }
  for (i in seq_len(n_gauges)) {
    id <- gauges_df$id[i]
    comps <- comps_list[[i]] %||% list(observed = NA_real_, forecast = NA_real_, nwm = NA_real_)
    observed_scores[i] <- score_stageflow_against_thresholds(comps$observed, gauges_df$action[i], gauges_df$flood[i], gauges_df$moderate[i], gauges_df$major[i])
    forecast_scores[i] <- score_stageflow_against_thresholds(comps$forecast, gauges_df$action[i], gauges_df$flood[i], gauges_df$moderate[i], gauges_df$major[i])
    nwm_scores[i] <- score_stageflow_against_thresholds(comps$nwm, gauges_df$action[i], gauges_df$flood[i], gauges_df$moderate[i], gauges_df$major[i])
    observed_labels[i] <- build_stageflow_reason_text(id, "observed", comps$observed, gauges_df$action[i], gauges_df$flood[i], gauges_df$moderate[i], gauges_df$major[i])
    forecast_labels[i] <- build_stageflow_reason_text(id, "forecast", comps$forecast, gauges_df$action[i], gauges_df$flood[i], gauges_df$moderate[i], gauges_df$major[i])
    nwm_labels[i] <- build_stageflow_reason_text(id, "nwm", comps$nwm, gauges_df$action[i], gauges_df$flood[i], gauges_df$moderate[i], gauges_df$major[i])
    score_vec <- c(observed = observed_scores[i], forecast = 0.95 * forecast_scores[i], nwm = 0.90 * nwm_scores[i])
    score_vec[!is.finite(score_vec)] <- 0
    dominant_source <- names(which.max(score_vec))
    live_scores[i] <- max(score_vec, na.rm = TRUE)
    live_sources[i] <- dominant_source
    live_labels[i] <- c(observed = observed_labels[i], forecast = forecast_labels[i], nwm = nwm_labels[i])[dominant_source]
  }
  gauges_sf$gauge_id <- gauges_df$id
  gauges_sf$action <- gauges_df$action
  gauges_sf$flood <- gauges_df$flood
  gauges_sf$moderate <- gauges_df$moderate
  gauges_sf$major <- gauges_df$major
  gauges_sf$observed_score <- observed_scores
  gauges_sf$forecast_score <- forecast_scores
  gauges_sf$nwm_score <- nwm_scores
  gauges_sf$observed_label <- observed_labels
  gauges_sf$forecast_label <- forecast_labels
  gauges_sf$nwm_label <- nwm_labels
  gauges_sf$live_score <- live_scores
  gauges_sf$live_label <- live_labels
  gauges_sf$live_source <- live_sources

  nearest_idx <- sf::st_nearest_feature(wi_zip_points, gauges_sf)
  out <- list(
    scores = live_scores[nearest_idx],
    labels = live_labels[nearest_idx],
    dominant_source = live_sources[nearest_idx],
    observed_scores = observed_scores[nearest_idx],
    forecast_scores = forecast_scores[nearest_idx],
    nwm_scores = nwm_scores[nearest_idx],
    observed_labels = observed_labels[nearest_idx],
    forecast_labels = forecast_labels[nearest_idx],
    nwm_labels = nwm_labels[nearest_idx],
    gauge_sf = gauges_sf
  )
  for (nm in c("scores", "labels", "dominant_source", "observed_scores", "forecast_scores", "nwm_scores", "observed_labels", "forecast_labels", "nwm_labels")) {
    names(out[[nm]]) <- wi_zctas$zipcode
  }
  out$scores[!is.finite(out$scores)] <- 0
  out$observed_scores[!is.finite(out$observed_scores)] <- 0
  out$forecast_scores[!is.finite(out$forecast_scores)] <- 0
  out$nwm_scores[!is.finite(out$nwm_scores)] <- 0
  cache_put("derived", key, out, ttl_seconds = 900)
  save_runtime_snapshot(snap_path, out)
  out
}

# Why: picks the right NWPS component (observed for live, forecast/NWM for
# future horizons) so the flood layer reflects the right time horizon.
# What: returns list(scores, labels, dominant_source) per ZIP for the
# requested horizon - takes the maximum across allowed components and the
# label from whichever component contributed the max.
# How: per ZIP, evaluates the allowed component scores (and a "carry
# forward" decay for fallback), keeps the max, records dominant_source
# accordingly.
# When: called by compute_nwps_corridor_signal once per (live + each
# future horizon) build.
# Impact: changing the per-horizon component policy here is the place to
# rebalance how live measurements vs forecast guidance drive the layer.
select_nwps_horizon_signal <- function(nwps_context, horizon_key = "live") {
  obs <- as.numeric(nwps_context$observed_scores %||% rep(0, nrow(wi_zctas)))
  fc <- as.numeric(nwps_context$forecast_scores %||% rep(0, length(obs)))
  nwm <- as.numeric(nwps_context$nwm_scores %||% rep(0, length(obs)))
  obs_lbl <- as.character(nwps_context$observed_labels %||% rep(NA_character_, length(obs)))
  fc_lbl <- as.character(nwps_context$forecast_labels %||% rep(NA_character_, length(obs)))
  nwm_lbl <- as.character(nwps_context$nwm_labels %||% rep(NA_character_, length(obs)))
  base_names <- names(nwps_context$observed_scores %||% NULL)
  if (is.null(base_names) || length(base_names) != length(obs)) base_names <- as.character(seq_along(obs))

  if (identical(horizon_key, "24h")) {
    obs_w <- apply_live_decay(obs, horizon_key, half_life_hours = 4)
    fc_w <- 1.00 * fc
    nwm_w <- 0.96 * nwm
  } else if (identical(horizon_key, "48h")) {
    obs_w <- apply_live_decay(obs, horizon_key, half_life_hours = 4)
    fc_w <- 0.82 * fc
    nwm_w <- 1.00 * nwm
  } else if (identical(horizon_key, "72h")) {
    obs_w <- apply_live_decay(obs, horizon_key, half_life_hours = 4)
    fc_w <- 0.60 * fc
    nwm_w <- 0.92 * nwm
  } else {
    obs_w <- 1.00 * obs
    fc_w <- 0.95 * fc
    nwm_w <- 0.90 * nwm
  }

  source_mat <- as.matrix(data.frame(observed = obs_w, forecast = fc_w, nwm = nwm_w, check.names = FALSE))
  source_mat[!is.finite(source_mat)] <- 0
  if (nrow(source_mat) == 0) {
    dominant_source <- character(0)
    scores <- numeric(0)
  } else {
    dominant_idx <- max.col(source_mat, ties.method = "first")
    dominant_source <- colnames(source_mat)[dominant_idx]
    scores <- do.call(pmax, c(as.data.frame(source_mat), list(na.rm = TRUE)))
  }
  labels <- ifelse(
    dominant_source == "observed",
    obs_lbl,
    ifelse(dominant_source == "forecast", fc_lbl, nwm_lbl)
  )
  names(scores) <- base_names
  names(labels) <- base_names
  names(dominant_source) <- base_names
  list(scores = scores, labels = labels, dominant_source = dominant_source)
}

# Why: the river-corridor flood signal needs both a per-zip score and a
# per-zip label tied to a specific gauge for the popup.
# What: returns list(scores, labels, dominant_source, gauge_sf) ready to
# fold into the flood total scoring.
# How: hands off to fetch_nwps_gauge_context and select_nwps_horizon_signal,
# annotating the gauge_sf with the chosen horizon's component scores.
# When: called by the flood scoring pipeline once per horizon.
# Impact: this is the public entry point for the river corridor; downstream
# code only sees the result, so changing the source split here has wide
# downstream effect.
compute_nwps_corridor_signal <- function(horizon_key = "live", nwps_context = NULL) {
  cache_name <- paste0("nwps-corridor-signal-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  if (is.null(nwps_context)) nwps_context <- fetch_nwps_gauge_context()
  gauge_sf <- nwps_context$gauge_sf %||% NULL
  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  out_sources <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  if (is.null(gauge_sf) || nrow(gauge_sf) == 0) {
    out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
    cache_put("derived", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
    return(out)
  }
  gauge_signal <- select_nwps_horizon_signal(list(
    observed_scores = stats::setNames(gauge_sf$observed_score, seq_len(nrow(gauge_sf))),
    forecast_scores = stats::setNames(gauge_sf$forecast_score, seq_len(nrow(gauge_sf))),
    nwm_scores = stats::setNames(gauge_sf$nwm_score, seq_len(nrow(gauge_sf))),
    observed_labels = stats::setNames(gauge_sf$observed_label, seq_len(nrow(gauge_sf))),
    forecast_labels = stats::setNames(gauge_sf$forecast_label, seq_len(nrow(gauge_sf))),
    nwm_labels = stats::setNames(gauge_sf$nwm_label, seq_len(nrow(gauge_sf)))
  ), horizon_key = horizon_key)
  gauge_scores <- unname(gauge_signal$scores)
  gauge_labels <- unname(gauge_signal$labels)
  gauge_sources <- unname(gauge_signal$dominant_source)
  gauge_scores[!is.finite(gauge_scores)] <- 0
  if (!any(gauge_scores > 0)) {
    out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
    cache_put("derived", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
    return(out)
  }
  zip_pts_proj <- wi_zip_points_proj
  gauge_proj <- suppressWarnings(sf::st_transform(gauge_sf, 5070))
  hits <- suppressWarnings(sf::st_is_within_distance(zip_pts_proj, gauge_proj, dist = 40000))
  # Bulk distance with CRS stripped: 861 ZIP points x N gauges (small).
  # Replaces 861 per-ZIP st_distance calls each paying the PROJ DB CRS
  # validation tax. Both inputs in EPSG:5070 by construction.
  zip_geom <- sf::st_geometry(zip_pts_proj)
  gauge_geom <- sf::st_geometry(gauge_proj)
  sf::st_crs(zip_geom) <- NA
  sf::st_crs(gauge_geom) <- NA
  d_full <- tryCatch({
    m <- suppressWarnings(sf::st_distance(zip_geom, gauge_geom))
    m <- matrix(as.numeric(m), nrow = length(zip_geom))
    m[!is.finite(m)] <- 40000
    m
  }, error = function(e) NULL)
  for (i in seq_along(hits)) {
    idx <- unique(as.integer(hits[[i]]))
    if (length(idx) == 0) next
    d <- if (!is.null(d_full)) d_full[i, idx] else {
      v <- safe_numeric(sf::st_distance(zip_geom[i], gauge_geom[idx]))
      v[!is.finite(v)] <- 40000
      v
    }
    proximity <- exp(-pmax(d, 0) / 16000)
    src_mult <- ifelse(gauge_sources[idx] == "nwm", 1.05, ifelse(gauge_sources[idx] == "forecast", 1.02, 1.00))
    local_scores <- pmin(1, gauge_scores[idx] * proximity * src_mult)
    if (!any(is.finite(local_scores) & local_scores > 0)) next
    best <- which.max(local_scores)[1]
    out_scores[i] <- local_scores[best]
    lbl <- gauge_labels[idx[best]] %||% "Nearby river-corridor guidance indicates elevated flood risk."
    out_reasons[i] <- paste0(as.character(lbl), " Nearby river-corridor conditions are influencing this ZIP.")
    out_sources[i] <- gauge_sources[idx[best]]
  }
  out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
  cache_put("derived", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
  out
}
