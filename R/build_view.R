# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/build_view.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

build_forecast_baseline <- function(horizon_key = "live") {
  cache_name <- paste0("forecast-baseline-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) {
    if (!"temperature_pressure_text" %in% names(cached)) {
      cached <- append_temperature_pressure_fields(cached)
      cache_put("derived", cache_name, cached, ttl_seconds = FORECAST_TTL_SECONDS)
    }
    return(cached)
  }
  snapshot_path <- file.path(RUNTIME_CACHE_DIR, sprintf("forecast_baseline_%s.rds", gsub("[^a-z0-9]+", "_", horizon_key %||% "live")))
  persisted <- load_runtime_snapshot(snapshot_path, max_age_seconds = FORECAST_TTL_SECONDS)
  if (!is.null(persisted)) {
    if (!"temperature_pressure_text" %in% names(persisted)) {
      persisted <- append_temperature_pressure_fields(persisted)
      save_runtime_snapshot(snapshot_path, persisted)
    }
    cache_put("derived", cache_name, persisted, ttl_seconds = FORECAST_TTL_SECONDS)
    return(persisted)
  }

  zips <- zip_static
  zips <- apply_cached_place_names(zips)
  zips$horizon_label <- switch(horizon_key %||% "live", live = "Live", `24h` = "24hrs", `48h` = "48hrs", `72h` = "72hrs", "Live")
  zips$forecast_score <- 0
  zips$temp_risk_score <- 0
  zips$wind_risk_score <- 0
  zips$pop_risk_score <- 0
  zips$forecast_temperature_f <- NA_real_
  zips$forecast_wind_mph <- NA_real_
  zips$forecast_wind_dir <- NA_character_
  zips$forecast_wind_dir_degrees <- NA_real_
  zips$forecast_pop_pct <- NA_real_
  zips$forecast_short <- NA_character_

  region_ids <- sort(unique(as.integer(zips$forecast_region)))
  region_ids <- region_ids[is.finite(region_ids)]
  region_forecasts <- lapply(region_ids, function(region_id) fetch_forecast_for_region(region_id, horizon_key))
  names(region_forecasts) <- as.character(region_ids)

  lookup <- lapply(as.character(zips$forecast_region), function(k) {
    item <- region_forecasts[[k]]
    if (is.null(item)) empty_forecast_result() else item
  })

  zips$forecast_temperature_f <- vapply(lookup, function(x) x$temperature_f %||% NA_real_, numeric(1))
  zips$forecast_wind_mph <- vapply(lookup, function(x) x$wind_mph %||% NA_real_, numeric(1))
  zips$forecast_wind_dir <- vapply(lookup, function(x) x$wind_direction %||% NA_character_, character(1))
  zips$forecast_wind_dir_degrees <- vapply(lookup, function(x) x$wind_direction_degrees %||% NA_real_, numeric(1))
  zips$forecast_pop_pct <- vapply(lookup, function(x) x$pop_pct %||% NA_real_, numeric(1))
  zips$forecast_short <- vapply(lookup, function(x) x$short_forecast %||% NA_character_, character(1))
  profile_idx <- match(zips$lat_band, risk_band_profiles$lat_band)
  profile_idx[!is.finite(profile_idx)] <- 1L
  profile_rows <- risk_band_profiles[profile_idx, , drop = FALSE]
  comfort_low <- suppressWarnings(as.numeric(profile_rows$temp_comfort_low_f))
  comfort_high <- suppressWarnings(as.numeric(profile_rows$temp_comfort_high_f))
  record_low <- suppressWarnings(as.numeric(profile_rows$temp_record_low_f))
  record_high <- suppressWarnings(as.numeric(profile_rows$temp_record_high_f))
  temp_vals <- suppressWarnings(as.numeric(zips$forecast_temperature_f))
  zips$temp_risk_score <- rep(0, nrow(zips))
  temp_valid <- is.finite(temp_vals) & is.finite(comfort_low) & is.finite(comfort_high) & is.finite(record_low) & is.finite(record_high)
  temp_cold <- temp_valid & temp_vals < comfort_low
  temp_hot <- temp_valid & temp_vals > comfort_high
  zips$temp_risk_score[temp_cold] <- pmin(1, (comfort_low[temp_cold] - temp_vals[temp_cold]) / pmax(comfort_low[temp_cold] - record_low[temp_cold], 1e-9))
  zips$temp_risk_score[temp_hot] <- pmin(1, (temp_vals[temp_hot] - comfort_high[temp_hot]) / pmax(record_high[temp_hot] - comfort_high[temp_hot], 1e-9))
  zips$wind_risk_score <- vector_piecewise_score_rowwise(
    zips$forecast_wind_mph,
    profile_rows$low_wind_mph,
    profile_rows$medium_wind_mph,
    profile_rows$high_wind_mph
  )
  zips$pop_risk_score <- vector_piecewise_score_rowwise(
    zips$forecast_pop_pct,
    profile_rows$low_pop_pct,
    profile_rows$medium_pop_pct,
    profile_rows$high_pop_pct
  )
  zips$forecast_score <- pmin(1, 0.45 * zips$temp_risk_score + 0.30 * zips$wind_risk_score + 0.25 * zips$pop_risk_score)
  zips <- append_temperature_pressure_fields(zips)

  cache_put("derived", cache_name, zips, ttl_seconds = FORECAST_TTL_SECONDS)
  save_runtime_snapshot(snapshot_path, zips)
  zips
}

# Why: rendering all ~770 ZIP polygons in one synchronous pass freezes the
# Shiny worker for several seconds, and most ticks only change a small subset
# of rows. Building the view in latitude bands (north-to-south) lets the UI
# show the user-visible top half quickly while the rest streams in, and the
# per-band diff against the previous tick lets us skip popup/render-signature
# regeneration for unchanged rows.
# What: returns zips with the per-row display columns populated
# (fill_risk_score, display_risk_label, risk_fill_rgba, *_reason_text,
# popup_label, render_signature, driving_total_risk, etc.).
# How: precomputes the previous-tick state from the "view-state-..." cache
# entry, then iterates north-to-south band groups; per band, recomputes
# driving risk and primary-map fill, runs the reason-text composers, and
# only rebuilds popup_label / render_signature for rows that changed against
# the previous tick (zip_view_changed_rows).
# When: the last stage in build_risk_polygons; runs once per plotted view.
# Impact: the cached "view-state-..." key is what enables incremental popup
# rebuilds — clearing it forces a full rebuild on the next tick (slower but
# safe). progress_span sets how much of the build_risk_polygons progress bar
# this stage occupies (default 0.84 -> 0.98).
finalize_zip_view <- function(zips, horizon_key, feature_key, primary_map = DEFAULT_PRIMARY_MAP, progress = NULL, progress_span = c(0.84, 0.98)) {
  primary_map <- normalize_primary_map(primary_map)
  zips$primary_map_key <- rep(primary_map, nrow(zips))
  zips$risk_label <- vapply(zips$normalized_risk_score, risk_label_from_score, character(1))
  state_key <- paste0("view-state-", horizon_key, "-", feature_key)
  prev <- cache_get("derived", state_key)
  prev_valid <- !is.null(prev) && nrow(prev) == nrow(zips) && identical(prev$zipcode, zips$zipcode)

  n <- nrow(zips)
  zips$fill_risk_score <- rep(0, n)
  zips$display_risk_label <- rep("Transparent", n)
  zips$risk_fill_rgba <- rep(risk_rgba(0), n)
  zips$risk_reason_text <- rep("All clear.", n)
  zips$risk_component_summary_text <- rep("No material contributors.", n)
  zips$risk_type_summary_text <- rep("No material contributors.", n)
  zips$driving_total_risk <- rep(0, n)
  zips$driving_reason_text <- rep("All clear.", n)
  zips$driving_risk_label <- rep("Transparent", n)
  zips$popup_label <- rep("", n)
  zips$render_signature <- rep("", n)

  if (isTRUE(prev_valid)) {
    zips$popup_label <- prev$popup_label
    zips$render_signature <- prev$render_signature
  }

  band_groups <- latitude_band_row_groups(zips, descending = TRUE)
  total_bands <- max(1L, length(band_groups))
  progress_start <- progress_span[1] %||% 0.84
  progress_end <- progress_span[2] %||% 0.98
  compare_cols <- zip_view_compare_columns()
  assign_cols <- c(
    "fill_risk_score", "display_risk_label", "risk_fill_rgba",
    "risk_reason_text", "risk_component_summary_text", "risk_type_summary_text",
    "driving_total_risk", "driving_reason_text", "driving_risk_label",
    "popup_label", "render_signature"
  )

  for (band_idx in seq_along(band_groups)) {
    idx <- band_groups[[band_idx]]
    if (length(idx) == 0) next
    band <- zips[idx, , drop = FALSE]
    band <- compute_driving_risk(band)
    band$fill_risk_score <- compute_primary_fill_score(band, primary_map = primary_map)
    band$display_risk_label <- vapply(band$fill_risk_score, risk_label_from_score, character(1))
    band$risk_fill_rgba <- risk_rgba(band$fill_risk_score)

    band_df <- sf::st_drop_geometry(band)
    zip_row_summaries <- lapply(seq_len(nrow(band_df)), function(i) {
      row <- band_df[i, , drop = FALSE]
      list(
        reason = compose_risk_reason(row),
        components = compose_risk_component_summary(row),
        types = compose_risk_type_summary(row)
      )
    })
    band$risk_reason_text <- vapply(zip_row_summaries, function(x) x$reason %||% "All clear.", character(1))
    band$risk_component_summary_text <- vapply(zip_row_summaries, function(x) x$components %||% "No material contributors.", character(1))
    band$risk_type_summary_text <- vapply(zip_row_summaries, function(x) x$types %||% "No material contributors.", character(1))

    changed <- rep(TRUE, nrow(band))
    if (isTRUE(prev_valid)) {
      prev_band <- prev[idx, , drop = FALSE]
      band$popup_label <- prev_band$popup_label
      band$render_signature <- prev_band$render_signature
      changed <- zip_view_changed_rows(sf::st_drop_geometry(band), prev_band, compare_cols = compare_cols)
    }
    if (any(changed)) {
      changed_rows <- sf::st_drop_geometry(band[changed, , drop = FALSE])
      band$popup_label[changed] <- build_popup_vectorized(changed_rows)
      band$render_signature[changed] <- zip_render_signature_vector(band[changed, , drop = FALSE])
    }

    for (col in assign_cols) {
      zips[[col]][idx] <- band[[col]]
    }

    notify_progress(
      progress,
      value = progress_start + (progress_end - progress_start) * (band_idx / total_bands),
      detail = sprintf("Finalizing Wisconsin band %d of %d from north to south.", band_idx, total_bands)
    )

    rm(band, band_df, zip_row_summaries)
    if (exists("changed_rows", inherits = FALSE)) rm(changed_rows)
    release_runtime_memory()
  }

  state_cols <- intersect(c(
    "zipcode", zip_view_compare_columns(), "popup_label", "render_signature"
  ), names(zips))
  state_df <- sf::st_drop_geometry(zips[, state_cols, drop = FALSE])
  cache_put("derived", state_key, state_df, ttl_seconds = if (identical(horizon_key, "live")) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  release_runtime_memory()
  zips
}

# Adds (or zeroes) the per-ZIP alert columns that downstream stages assume exist (alert_score, per-family alert scores, alert_event/url and alert_event_list/url_list, risk_reason_text) — used both before apply_alert_coverage_to_zips and as a defensive reset inside it.
initialize_zip_alert_fields <- function(zips) {
  zips$alert_score <- 0
  zips$alert_event <- NA_character_
  zips$alert_url <- NA_character_
  zips$alert_event_list <- NA_character_
  zips$alert_url_list <- NA_character_
  zips$flood_alert_score <- 0
  zips$winter_alert_score <- 0
  zips$convective_alert_score <- 0
  zips$fire_alert_score <- 0
  zips$wind_alert_score <- 0
  zips$heat_alert_score <- 0
  zips$cold_alert_score <- 0
  zips$air_alert_score <- 0
  zips$radiation_alert_score <- 0
  zips$seismic_alert_score <- 0
  zips$risk_reason_text <- NA_character_
  zips
}

# Why: the NWS alert payload is a list of (alert -> zipcodes) pairs and
# (alert -> calc_score / event / url) metadata; we need to project that into
# per-ZIP columns the rest of the pipeline can read directly.
# What: returns zips with alert_score, alert_event, alert_url,
# alert_event_list, alert_url_list, and the ten per-family alert scores
# (flood_alert_score, winter_alert_score, ..., seismic_alert_score) populated
# from alert_payload, filtered to the horizon.
# How: filters alert_payload by horizon, scores each alert via score_nws_alert,
# expands to one row per (alert_id, zipcode), keeps the highest-scoring alert
# per zip as the "primary" event, gathers up to three (event, url) pairs per
# zip into ALERT_LINK_SEP-joined lists, and computes per-family max scores
# via tapply() with alert_matches_family.
# When: called from build_risk_polygons after enrich_external_risks and
# before apply_family_risk_totals.
# Impact: ALERT_LINK_SEP is the contract with popups.R for splitting list
# entries on the client; a different separator silently breaks popup rendering.
apply_alert_coverage_to_zips <- function(zips, alert_payload, horizon_key = "live") {
  zips <- initialize_zip_alert_fields(zips)
  alert_payload <- filter_alert_payload_for_horizon(alert_payload, horizon_key = horizon_key)
  alerts_df <- alert_payload$alerts_df %||% data.frame()
  if (nrow(alerts_df) == 0) return(zips)

  active_df <- alerts_df
  active_df$alert_calc_score <- mapply(score_nws_alert, active_df$event, active_df$severity, active_df$urgency, active_df$certainty)
  active_df$sent_num <- vapply(active_df$sent, function(x) as.numeric(parse_iso_time(x)), numeric(1))
  active_df$disaster_type <- vapply(active_df$event, categorize_alert_type, character(1))
  zip_rows <- lapply(
    seq_len(nrow(active_df)),
    function(i) {
      zipcodes <- unique(as.character(alert_payload$alert_zip_map[[active_df$alert_id[i]]] %||% character(0)))
      zipcodes <- zipcodes[nzchar(zipcodes)]
      if (length(zipcodes) == 0) return(NULL)
      data.frame(alert_id = active_df$alert_id[i], zipcode = zipcodes, stringsAsFactors = FALSE)
    }
  )
  zip_rows <- Filter(Negate(is.null), zip_rows)
  if (length(zip_rows) == 0) return(zips)

  zip_alert_df <- dplyr::bind_rows(zip_rows)
  merged_alerts <- merge(
    zip_alert_df,
    active_df[, c("alert_id", "alert_calc_score", "event", "url", "sent_num", "disaster_type")],
    by = "alert_id",
    all.x = TRUE,
    sort = FALSE
  )
  best_df <- merged_alerts[order(merged_alerts$zipcode, -merged_alerts$alert_calc_score, -merged_alerts$sent_num), , drop = FALSE]
  best_df <- best_df[!duplicated(best_df$zipcode), , drop = FALSE]
  match_idx <- match(zips$zipcode, best_df$zipcode)
  keep_zip <- !is.na(match_idx)
  if (any(keep_zip)) {
    zips$alert_score[keep_zip] <- best_df$alert_calc_score[match_idx[keep_zip]]
    zips$alert_event[keep_zip] <- best_df$event[match_idx[keep_zip]]
    zips$alert_url[keep_zip] <- best_df$url[match_idx[keep_zip]]
  }

  merged_alerts <- merged_alerts[order(merged_alerts$zipcode, -merged_alerts$alert_calc_score, -merged_alerts$sent_num), , drop = FALSE]
  alert_lists <- lapply(split(seq_len(nrow(merged_alerts)), merged_alerts$zipcode), function(idx_vec) {
    subset_df <- merged_alerts[idx_vec, c("event", "url"), drop = FALSE]
    event_txt <- trimws(as.character(subset_df$event %||% ""))
    url_txt <- trimws(as.character(subset_df$url %||% ""))
    pair_key <- paste(event_txt, url_txt, sep = "\r")
    keep_idx <- !duplicated(pair_key) & nzchar(event_txt)
    subset_df <- subset_df[keep_idx, , drop = FALSE]
    if (nrow(subset_df) > 3L) subset_df <- subset_df[seq_len(3L), , drop = FALSE]
    list(
      events = paste(as.character(subset_df$event), collapse = ALERT_LINK_SEP),
      urls = paste(ifelse(is.na(subset_df$url), "", as.character(subset_df$url)), collapse = ALERT_LINK_SEP)
    )
  })
  list_names <- names(alert_lists)
  list_match <- match(zips$zipcode, list_names)
  keep_list <- !is.na(list_match)
  if (any(keep_list)) {
    zips$alert_event_list[keep_list] <- vapply(alert_lists[list_match[keep_list]], function(x) x$events %||% NA_character_, character(1))
    zips$alert_url_list[keep_list] <- vapply(alert_lists[list_match[keep_list]], function(x) x$urls %||% NA_character_, character(1))
  }

  type_max <- function(type_name) {
    event_matches <- vapply(merged_alerts$event, alert_matches_family, logical(1), family = type_name)
    tapply(ifelse(event_matches, merged_alerts$alert_calc_score, 0), merged_alerts$zipcode, max)
  }
  flood_map <- type_max("flood")
  winter_map <- type_max("winter")
  convective_map <- type_max("convective")
  fire_map <- type_max("fire")
  wind_map <- type_max("wind")
  heat_map <- type_max("heat")
  cold_map <- type_max("cold")
  air_map <- type_max("air")
  radiation_map <- type_max("radiation")
  seismic_map <- type_max("seismic")
  zips$flood_alert_score <- unname(flood_map[zips$zipcode]); zips$flood_alert_score[!is.finite(zips$flood_alert_score)] <- 0
  zips$winter_alert_score <- unname(winter_map[zips$zipcode]); zips$winter_alert_score[!is.finite(zips$winter_alert_score)] <- 0
  zips$convective_alert_score <- unname(convective_map[zips$zipcode]); zips$convective_alert_score[!is.finite(zips$convective_alert_score)] <- 0
  zips$fire_alert_score <- unname(fire_map[zips$zipcode]); zips$fire_alert_score[!is.finite(zips$fire_alert_score)] <- 0
  zips$wind_alert_score <- unname(wind_map[zips$zipcode]); zips$wind_alert_score[!is.finite(zips$wind_alert_score)] <- 0
  zips$heat_alert_score <- unname(heat_map[zips$zipcode]); zips$heat_alert_score[!is.finite(zips$heat_alert_score)] <- 0
  zips$cold_alert_score <- unname(cold_map[zips$zipcode]); zips$cold_alert_score[!is.finite(zips$cold_alert_score)] <- 0
  zips$air_alert_score <- unname(air_map[zips$zipcode]); zips$air_alert_score[!is.finite(zips$air_alert_score)] <- 0
  zips$radiation_alert_score <- unname(radiation_map[zips$zipcode]); zips$radiation_alert_score[!is.finite(zips$radiation_alert_score)] <- 0
  zips$seismic_alert_score <- unname(seismic_map[zips$zipcode]); zips$seismic_alert_score[!is.finite(zips$seismic_alert_score)] <- 0
  zips
}

# Why: each hazard family (flood, winter, fire, wind, heat, cold, air,
# convective, radiation, seismic) is sourced from several feeds with
# different scales and reliability; this is the single fusion stage that
# blends each feed into a 0..1 family total used by the rest of the app.
# What: returns zips with *_total_score and *_reason_text columns populated
# for every hazard family, plus the intermediate flood_*_component columns
# used by the popup breakdown.
# How: builds a small set of helper signals first (smoke_air_proxy,
# heat_signal, flash_flood_signal, convective_live_support), then for each
# family blends the relevant feeds via blend_alert_signal with family-
# specific alert weights, and finally derives reason_text from whichever
# component is the dominant contributor.
# When: called from build_risk_polygons immediately after
# apply_alert_coverage_to_zips and before combine_environmental_risk_score.
# Impact: changing any of the alert_weight constants here re-tunes how
# heavily NWS alerts shift the family totals - the families with weight
# >= 0.85 (flood, ionizing, seismic) treat the alert as near-authoritative.
apply_family_risk_totals <- function(zips, horizon_key = "live") {
  smoke_air_proxy <- pmax(zips$air_alert_score %||% 0, zips$airnow_total_score %||% 0, 0.55 * (zips$fire_risk_score %||% 0), na.rm = TRUE)
  heat_signal <- pmax(zips$heatrisk_official_score %||% 0, zips$heat_risk_score %||% 0, na.rm = TRUE)
  cold_factor <- ifelse(is.finite(zips$forecast_temperature_f) & zips$forecast_temperature_f <= 34, 1, 0)
  alert_event_text <- as.character(zips$alert_event %||% rep("", nrow(zips)))
  convective_live_support <- if (identical(horizon_key, "live")) pmax(zips$convective_guidance_score %||% 0, zips$glm_lightning_total_score %||% 0, na.rm = TRUE) else (zips$convective_guidance_score %||% 0)
  flash_flood_signal <- pmax((zips$ffg_total_score %||% 0) * pmax(zips$qpf_risk_score %||% 0, convective_live_support, na.rm = TRUE), 0.60 * (zips$ffg_total_score %||% 0), na.rm = TRUE)
  zips$flood_alert_component <- soft_alert_signal(zips$flood_alert_score %||% 0, event = alert_event_text, weight = 0.95)
  zips$flood_qpf_component <- pmax(0.30 * (zips$qpf_risk_score %||% 0), 0)
  zips$flood_river_component <- pmax(0.18 * (zips$river_gauge_point_score %||% 0), 0)
  zips$flood_corridor_component <- pmax(0.08 * (zips$river_corridor_score %||% 0), 0)
  zips$flood_offgauge_component <- pmax(0.11 * pmax(0.85 * (zips$nwm_flood_outlook_score %||% 0), ifelse((zips$river_corridor_source %||% "") == "nwm", zips$river_corridor_score %||% 0, 0), na.rm = TRUE), 0)
  zips$flood_outlook_component <- pmax(0.14 * (zips$river_outlook_score %||% 0), 0)
  zips$flood_ffg_component <- pmax(0.16 * flash_flood_signal, 0)
  zips$flood_fho_component <- pmax(0.07 * (zips$nwm_flood_outlook_score %||% 0), 0)
  flood_base_signal <- pmin(1, zips$flood_qpf_component + zips$flood_river_component + zips$flood_corridor_component + zips$flood_offgauge_component + zips$flood_outlook_component + zips$flood_ffg_component + zips$flood_fho_component)
  winter_base_signal <- pmin(1, 0.55 * zips$winter_risk_score + 0.20 * zips$wind_risk_score + 0.25 * (zips$qpf_risk_score * cold_factor))
  air_base_signal <- pmin(1, smoke_air_proxy)
  fire_base_signal <- pmin(1, pmax(zips$fire_risk_score, 0.55 * air_base_signal, na.rm = TRUE))
  wind_base_signal <- pmin(1, pmax(zips$wind_risk_score, 0.45 * convective_live_support, na.rm = TRUE))
  heat_base_signal <- pmin(1, 1 - (1 - 0.75 * heat_signal) * (1 - 0.25 * (zips$uv_total_score %||% 0)))
  ionizing_base_signal <- pmin(1, pmax(zips$radnet_total_score %||% 0, zips$nrc_total_score %||% 0, na.rm = TRUE))
  zips$flood_total_score <- pmin(1, blend_alert_signal(flood_base_signal, zips$flood_alert_score %||% 0, event = alert_event_text, alert_weight = 0.95))
  zips$winter_total_score <- pmin(1, blend_alert_signal(winter_base_signal, zips$winter_alert_score %||% 0, event = alert_event_text, alert_weight = 0.72))
  zips$fire_total_score <- pmin(1, blend_alert_signal(fire_base_signal, zips$fire_alert_score %||% 0, event = alert_event_text, alert_weight = 0.60))
  zips$wind_total_score <- pmin(1, blend_alert_signal(wind_base_signal, zips$wind_alert_score %||% 0, event = alert_event_text, alert_weight = 0.72))
  zips$heat_total_score <- pmin(1, blend_alert_signal(heat_base_signal, zips$heat_alert_score %||% 0, event = alert_event_text, alert_weight = 0.58))
  zips$cold_total_score <- pmin(1, blend_alert_signal(0.70 * (zips$cold_risk_score %||% 0) + 0.30 * (zips$winter_total_score %||% 0), zips$cold_alert_score %||% 0, event = alert_event_text, alert_weight = 0.62))
  zips$air_total_score <- pmin(1, blend_alert_signal(air_base_signal, zips$air_alert_score %||% 0, event = alert_event_text, alert_weight = 0.58))
  zips$ionizing_total_score <- pmin(1, blend_alert_signal(ionizing_base_signal, zips$radiation_alert_score %||% 0, event = alert_event_text, alert_weight = 0.92))
  zips$radiation_total_score <- pmin(1, 1 - (1 - 0.85 * (zips$ionizing_total_score %||% 0)) * (1 - 0.35 * (zips$uv_total_score %||% 0)))
  zips$seismic_total_score <- pmin(1, blend_alert_signal(if (identical(horizon_key, "live")) zips$seismic_live_score else apply_live_decay(zips$seismic_live_score, horizon_key, half_life_hours = 48), zips$seismic_alert_score %||% 0, event = alert_event_text, alert_weight = 0.92))
  convective_base_signal <- pmin(1, pmax(convective_live_support, 0.60 * zips$wind_total_score + 0.40 * zips$pop_risk_score, na.rm = TRUE))
  zips$convective_total_score <- pmin(1, blend_alert_signal(convective_base_signal, zips$convective_alert_score %||% 0, event = alert_event_text, alert_weight = 0.78))
  zips$flood_reason_text <- ifelse(
    (zips$flood_alert_score %||% 0) >= pmax(zips$qpf_risk_score %||% 0, zips$river_gauge_point_score %||% 0, zips$river_corridor_score %||% 0, zips$river_outlook_score %||% 0, zips$ffg_total_score %||% 0, zips$nwm_flood_outlook_score %||% 0, na.rm = TRUE) & nzchar(trimws(as.character(zips$alert_event %||% ""))),
    as.character(zips$alert_event %||% ""),
    ifelse(
      (zips$river_gauge_point_score %||% 0) >= pmax(zips$qpf_risk_score %||% 0, zips$river_corridor_score %||% 0, zips$river_outlook_score %||% 0, zips$ffg_total_score %||% 0, zips$nwm_flood_outlook_score %||% 0, na.rm = TRUE),
      ifelse(nzchar(trimws(as.character(zips$river_gauge_point_reason_text %||% zips$river_gauge_reason_text %||% ""))), as.character(zips$river_gauge_point_reason_text %||% zips$river_gauge_reason_text %||% ""), "Observed or forecast river-gauge conditions are the primary flood driver near this ZIP."),
      ifelse(
        (zips$flood_offgauge_component %||% 0) >= pmax(zips$qpf_risk_score %||% 0, zips$river_corridor_score %||% 0, zips$river_outlook_score %||% 0, zips$ffg_total_score %||% 0, zips$nwm_flood_outlook_score %||% 0, na.rm = TRUE),
        "Off-gauge hydrologic guidance is the primary flood driver near this ZIP.",
        ifelse(
          (zips$river_corridor_score %||% 0) >= pmax(zips$qpf_risk_score %||% 0, zips$river_outlook_score %||% 0, zips$ffg_total_score %||% 0, zips$nwm_flood_outlook_score %||% 0, na.rm = TRUE),
          ifelse(nzchar(trimws(as.character(zips$river_corridor_reason_text %||% ""))), as.character(zips$river_corridor_reason_text %||% ""), "Nearby river-corridor forecast or National Water Model guidance is the primary flood driver near this ZIP."),
          ifelse(
            (zips$ffg_total_score %||% 0) >= pmax(zips$qpf_risk_score %||% 0, zips$river_outlook_score %||% 0, zips$nwm_flood_outlook_score %||% 0, na.rm = TRUE),
            "Flash-flood guidance and rainfall support indicate elevated rapid-onset flooding risk.",
            ifelse(
              (zips$nwm_flood_outlook_score %||% 0) >= pmax(zips$qpf_risk_score %||% 0, zips$river_outlook_score %||% 0, na.rm = TRUE),
              "NOAA flood-hazard outlook guidance indicates elevated flood potential.",
              ifelse((zips$qpf_risk_score %||% 0) >= pmax(zips$river_outlook_score %||% 0, 0, na.rm = TRUE), "Heavy precipitation guidance is the primary flood driver near this ZIP.", "Flood risk is elevated by combined river, rainfall, flash-flood, and river-corridor guidance.")
            )
          )
        )
      )
    )
  )
  zips$convective_reason_text <- ifelse(
    (zips$convective_alert_score %||% 0) >= pmax(zips$convective_guidance_score %||% 0, zips$glm_lightning_live_score %||% 0, zips$wind_total_score %||% 0, zips$pop_risk_score %||% 0, na.rm = TRUE) & nzchar(trimws(as.character(zips$alert_event %||% ""))),
    as.character(zips$alert_event %||% ""),
    ifelse(
      identical(horizon_key, "live") & (zips$glm_lightning_live_score %||% 0) >= pmax(zips$convective_guidance_score %||% 0, 0.60 * (zips$wind_total_score %||% 0) + 0.40 * (zips$pop_risk_score %||% 0), na.rm = TRUE) & nzchar(trimws(as.character(zips$glm_lightning_reason_text %||% ""))),
      as.character(zips$glm_lightning_reason_text %||% ""),
      ifelse((zips$convective_guidance_score %||% 0) >= pmax(zips$glm_lightning_live_score %||% 0, 0.60 * (zips$wind_total_score %||% 0) + 0.40 * (zips$pop_risk_score %||% 0), na.rm = TRUE), "SPC severe-convective guidance is the primary thunderstorm signal near this ZIP.", "Thunderstorm, hail, lightning, or severe convective conditions are the primary risk.")
    )
  )
  zips$radiation_reason_text <- ifelse(
    (zips$nrc_total_score %||% 0) >= pmax(zips$radnet_total_score %||% 0, zips$uv_total_score %||% 0, na.rm = TRUE) & nzchar(trimws(as.character(zips$nrc_event_text %||% ""))),
    as.character(zips$nrc_event_text %||% ""),
    ifelse((zips$radnet_total_score %||% 0) >= pmax(zips$uv_total_score %||% 0, 0, na.rm = TRUE) & nzchar(trimws(as.character(zips$radnet_reason_text %||% ""))), as.character(zips$radnet_reason_text %||% ""), "Radiation exposure risk elevated by UV or radiological conditions.")
  )
  zips
}

# Why: the entire app revolves around one normalised per-ZIP risk score; this
# function is the single source of truth that fuses every hazard feed into
# that score so map layers, route risk, and exposure summaries stay in sync.
# What: returns an sf data.frame of WI ZCTAs with raw feature columns,
# normalised feature columns, normalized_risk_score, dominant_zip metadata,
# render_signature, and any layer-specific exposure fields the UI needs.
# How: pulls each enabled feature's payload (NWS, FFG, SPC convective, AirNow,
# heat, alerts, families, etc.), aligns them to the WI ZCTA grid, applies the
# project's normalisation rules, and combines them via the scoring tables.
# External feeds can be served from cache or refreshed on-demand depending on
# allow_stale_external/force_external_sync.
# When: called from server.R reactives whenever the user changes the horizon,
# selected features, or hits "Refresh"; also called by route planning to get
# the underlying risk grid.
# Impact: the most expensive non-routing call in the app - its render_signature
# is the cache key that downstream tile builders, route segments, and exposure
# views key off of, so any new feature must add itself to render_signature.
build_risk_polygons <- function(horizon_key = "live", selected_features = FAST_START_FEATURES, alert_payload = NULL, include_transport = FALSE, progress = NULL, primary_map = DEFAULT_PRIMARY_MAP, allow_stale_external = TRUE, schedule_external_refresh = TRUE, force_external_sync = FALSE, project_dir = getwd()) {
  display_features <- normalize_feature_selection(selected_features)
  primary_map <- normalize_primary_map(primary_map)
  feature_key <- paste(sort(unique(c(display_features, sprintf(".primary:%s", primary_map), if (isTRUE(include_transport)) ".transport" else character(0)))), collapse = ",")
  if (is.null(alert_payload)) {
    alert_payload <- fetch_wisconsin_alerts(force_refresh = FALSE)
  }
  alert_etag <- as.character(alert_payload$etag %||% "")
  external_bundle_token <- external_bundle_cache_token(horizon_key, display_features, include_transport = include_transport)
  cache_name <- paste0("risk-", horizon_key, "-", feature_key, "-", alert_etag, "-", external_bundle_token)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)

  notify_progress(progress, 0.08, sprintf("Loading %s forecast baseline.", switch(horizon_key %||% "live", live = "live", `24h` = "24-hour", `48h` = "48-hour", `72h` = "72-hour", "live")))
  core <- build_forecast_baseline(horizon_key)
  core <- initialize_zip_alert_fields(core)
  core <- enrich_external_risks(
    core,
    horizon_key,
    selected_features = display_features,
    include_transport = include_transport,
    progress = progress,
    progress_span = c(0.20, 0.72),
    allow_stale = allow_stale_external,
    schedule_refresh = schedule_external_refresh,
    force_sync = force_external_sync,
    project_dir = project_dir
  )

  notify_progress(progress, 0.74, "Applying alert coverage.")
  zips <- apply_alert_coverage_to_zips(core, alert_payload = alert_payload, horizon_key = horizon_key)
  core <- NULL
  release_runtime_memory()
  zips <- apply_family_risk_totals(zips, horizon_key = horizon_key)
  zips$normalized_risk_score <- combine_environmental_risk_score(zips)
  zips <- apply_proximity_boost(zips)
  notify_progress(progress, 0.84, "Preparing Wisconsin ZIP output in north-to-south bands.")
  zips <- finalize_zip_view(
    zips,
    horizon_key,
    feature_key,
    primary_map = primary_map,
    progress = progress,
    progress_span = c(0.84, 0.98)
  )
  notify_progress(progress, 1, "Map ready.")

  invalidate_replaced_live_payloads("derived", prefix = paste0("risk-", horizon_key, "-", feature_key, "-"), keep_key = cache_name)
  cache_put("derived", cache_name, zips, ttl_seconds = if (identical(horizon_key, "live")) max(120L, ALERT_TTL_SECONDS) else FORECAST_TTL_SECONDS)
  release_runtime_memory()
  zips
}

# Why: cold-start the user sees a blank map for many seconds while every
# external feed is fetched and the risk polygon stack is rebuilt from
# scratch; precomputing the live payload offline and saving it as a snapshot
# lets the next session paint immediately.
# What: returns a list(polys, roads, primary_map) representing a fully
# materialised live map view; also writes the same payload to the startup
# snapshot file via save_startup_map_snapshot.
# How: fetches alerts (short timeout, single try, allow_stale), builds the
# fast-live forecast baseline, runs build_risk_polygons with allow_stale=
# TRUE / force_external_sync=TRUE / schedule_external_refresh=FALSE, and
# computes the matching driving roads overlay.
# When: invoked by the warm_live_startup_snapshot.R script (kicked off by
# schedule_live_startup_payload_prefetch in the background).
# Impact: a stale payload fed back into save_startup_map_snapshot is what
# the next session warms from — the STARTUP_WARMER_TRIGGER_AGE_SECONDS
# guard on the launcher prevents writing too-stale snapshots.
prefetch_live_startup_payload <- function(force_refresh = FALSE, allow_stale = TRUE) {
  alert_payload <- fetch_wisconsin_alerts(
    force_refresh = force_refresh,
    timeout_seconds = 8L,
    max_tries = 1L,
    allow_stale = allow_stale
  )
  invisible(build_fast_live_baseline())
  polys <- build_risk_polygons(
    horizon_key = "live",
    selected_features = primary_map_features(DEFAULT_PRIMARY_MAP),
    alert_payload = alert_payload,
    include_transport = TRUE,
    primary_map = DEFAULT_PRIMARY_MAP,
    allow_stale_external = TRUE,
    schedule_external_refresh = FALSE,
    force_external_sync = TRUE,
    project_dir = getwd()
  )
  roads <- build_driving_roads_overlay(polys, horizon_key = "live")
  payload <- list(polys = polys, roads = roads, primary_map = DEFAULT_PRIMARY_MAP)
  save_startup_map_snapshot(payload, horizon_key = "live", primary_map = DEFAULT_PRIMARY_MAP)
  payload
}

# Why: the live startup snapshot must be regenerated on a schedule (every
# few minutes) without blocking the foreground Shiny worker, so we shell
# out to a separate Rscript that runs prefetch_live_startup_payload.
# What: returns invisible(TRUE) when an Rscript was launched, FALSE when
# the snapshot is already fresh enough or another warmer is already active.
# How: skips when scripts/warm_live_startup_snapshot.R is missing, when the
# existing snapshot is younger than STARTUP_WARMER_TRIGGER_AGE_SECONDS, or
# when startup_warmer_active() detects an in-flight warmer; otherwise marks
# the warmer active and launches the script with system2(wait = FALSE).
# When: called from server.R after the initial map render, and again from
# the periodic refresh observer; idempotent so spurious calls are cheap.
# Impact: the lock file managed by mark_startup_warmer_active /
# clear_startup_warmer_active is what prevents concurrent warmers; if a
# warmer crashes without clearing the lock, the next valid call will not
# spawn a replacement until startup_warmer_active() ages out.
schedule_live_startup_payload_prefetch <- function(project_dir = getwd(), force = FALSE) {
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = FALSE)
  script_path <- file.path(project_dir, "scripts", "warm_live_startup_snapshot.R")
  if (!file.exists(script_path)) return(invisible(FALSE))
  if (!isTRUE(force) && startup_snapshot_fresh_enough(max_age_seconds = STARTUP_WARMER_TRIGGER_AGE_SECONDS)) {
    return(invisible(FALSE))
  }
  if (!isTRUE(force) && startup_warmer_active()) return(invisible(FALSE))

  dir.create(dirname(STARTUP_WARMER_LOG_PATH), recursive = TRUE, showWarnings = FALSE)
  mark_startup_warmer_active(project_dir = project_dir)
  rscript_bin <- file.path(R.home("bin"), "Rscript")
  launched <- tryCatch({
    system2(
      rscript_bin,
      args = c("--vanilla", script_path, project_dir),
      stdout = STARTUP_WARMER_LOG_PATH,
      stderr = STARTUP_WARMER_LOG_PATH,
      wait = FALSE
    )
    TRUE
  }, error = function(e) FALSE)
  if (!isTRUE(launched)) clear_startup_warmer_active()
  invisible(isTRUE(launched))
}

# Why: fetching the full external-risk bundle (NWPS gauges, FFG, AirNow,
# RadNet, NRC, GLM, WI511, etc.) takes 30-60s and must not block a tick;
# we shell out to a script that calls load_external_risk_bundle and writes
# the payload to disk so the next foreground build can read it instantly.
# What: returns invisible(TRUE) when an Rscript was launched, FALSE when
# the snapshot is already fresh or another warmer is in flight.
# How: skips when scripts/warm_external_risk_bundle.R is missing, when a
# fresh snapshot exists at external_bundle_snapshot_path(), or when an
# active warmer is detected; otherwise marks the warmer active and launches
# the script with the horizon, comma-joined feature list, and include_
# transport flag as positional args.
# When: invoked after each foreground risk-polygon build to keep the
# bundle warm for the next user interaction.
# Impact: per-(horizon, features, include_transport) lock files are what
# prevent two warmers competing for the same bundle; if one is stuck, the
# next call short-circuits until external_bundle_warmer_active times out.
schedule_external_risk_bundle_prefetch <- function(horizon_key = "live", selected_features = FAST_START_FEATURES, include_transport = FALSE, project_dir = getwd(), force = FALSE) {
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = FALSE)
  script_path <- file.path(project_dir, "scripts", "warm_external_risk_bundle.R")
  if (!file.exists(script_path)) return(invisible(FALSE))
  if (!isTRUE(force)) {
    fresh <- load_runtime_snapshot(
      external_bundle_snapshot_path(horizon_key, selected_features, include_transport = include_transport),
      max_age_seconds = external_bundle_fresh_age_seconds(horizon_key)
    )
    if (!is.null(fresh)) return(invisible(FALSE))
  }
  if (!isTRUE(force) && external_bundle_warmer_active(horizon_key, selected_features, include_transport = include_transport)) {
    return(invisible(FALSE))
  }

  dir.create(RUNTIME_CACHE_DIR, recursive = TRUE, showWarnings = FALSE)
  log_path <- external_bundle_log_path(horizon_key, selected_features, include_transport = include_transport)
  mark_external_bundle_warmer_active(horizon_key, selected_features, include_transport = include_transport, project_dir = project_dir)
  rscript_bin <- file.path(R.home("bin"), "Rscript")
  feature_arg <- paste(normalize_feature_selection(selected_features), collapse = ",")
  launched <- tryCatch({
    system2(
      rscript_bin,
      args = c("--vanilla", script_path, project_dir, horizon_key, feature_arg, if (isTRUE(include_transport)) "1" else "0"),
      stdout = log_path,
      stderr = log_path,
      wait = FALSE
    )
    TRUE
  }, error = function(e) FALSE)
  if (!isTRUE(launched)) {
    clear_external_bundle_warmer_active(horizon_key, selected_features, include_transport = include_transport)
  }
  invisible(isTRUE(launched))
}

# Why: when the user toggles to a future horizon (24h/48h/72h) we want the
# corresponding forecast baseline and external bundle pre-warmed so the
# subsequent build_risk_polygons call doesn't refetch the same data.
# What: returns invisibly; side effects are cache priming and (for live)
# kicking off the live-startup warmer.
# How: dispatches on horizon_key — "live_startup_payload" schedules the
# live-startup warmer; "live" rebuilds fast-live + forecast baselines and
# schedules the external bundle warmer; everything else just builds the
# forecast baseline and schedules the external bundle warmer.
# When: invoked from server.R as a future / observe so horizon switching
# feels instant from the user's perspective.
# Impact: the only entry point that calls invalidate_cache_prefix on
# "risk-live-" — without that, switching back to live could serve stale
# polygons that pre-date the latest baseline rebuild.
prefetch_horizon <- function(horizon_key) {
  if (identical(horizon_key, "live_startup_payload")) {
    return(invisible(schedule_live_startup_payload_prefetch()))
  }
  if (identical(horizon_key, "live")) {
    invisible(build_fast_live_baseline())
    invisible(build_forecast_baseline("live"))
    invalidate_cache_prefix("derived", "risk-live-")
    invisible(schedule_external_risk_bundle_prefetch("live", selected_features = primary_map_features(DEFAULT_PRIMARY_MAP), include_transport = TRUE))
  } else {
    invisible(build_forecast_baseline(horizon_key))
    invisible(schedule_external_risk_bundle_prefetch(horizon_key, selected_features = primary_map_features(DEFAULT_PRIMARY_MAP), include_transport = TRUE))
  }
}
