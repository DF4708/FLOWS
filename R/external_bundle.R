# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/external_bundle.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: produce the slow "external guidance" bundle (river gauges, NWM, FFG,
# QPF, fire, convective, lightning, heat, UV, AirNow, RadNet, NRC, seismic,
# WI511) for every selected feature in one pass.
# What: returns a zips data.frame populated with all bundle columns; can
# also persist partial progress to a snapshot file when persist_partial=TRUE.
# How: walks the build_external_module_plan in a fixed order, calls each
# module's loader, fills the corresponding columns, periodically saves
# partial snapshots so a crash mid-build is not catastrophic.
# When: invoked synchronously in the foreground when no usable snapshot
# exists, or in the background warmer for refreshes.
# Impact: this is the heaviest function in the app - any extra fetch added
# here lengthens cold-start time; persist_partial is the recovery hook.
compute_external_risk_bundle <- function(zips, horizon_key = "live", selected_features = FAST_START_FEATURES, include_transport = FALSE, progress = NULL, progress_span = c(0.35, 0.78), snapshot_path = NULL, persist_partial = FALSE) {
  requirements <- compute_feature_requirements(selected_features, include_transport = include_transport)
  zips <- initialize_external_risk_columns(zips)

  module_plan <- build_external_module_plan(horizon_key, selected_features = selected_features, include_transport = include_transport)
  module_plan_map <- build_external_module_plan_map(module_plan)
  module_entry <- function(id) {
    entry <- module_plan_map[[id]]
    if (is.null(entry)) {
      list(id = id, label = id, active = FALSE, mode = "skip", half_life_hours = NA_real_)
    } else {
      entry
    }
  }

  active_steps <- vapply(module_plan, function(entry) as.character(entry$label %||% entry$id %||% ""), character(1))
  progress_index <- 0L
  total_steps <- length(active_steps)
  progress_start <- progress_span[1] %||% 0.35
  progress_end <- progress_span[2] %||% 0.78
  band_groups <- latitude_band_row_groups(zips, descending = TRUE)
  total_bands <- max(1L, length(band_groups))

  live_support_bundle <- if (!identical(horizon_key %||% "live", "live") && any(vapply(module_plan, function(entry) identical(entry$mode, "carry_forward"), logical(1)))) {
    load_live_external_support_bundle(selected_features = selected_features, include_transport = include_transport)
  } else {
    NULL
  }

  support_named_numeric <- function(column, default = 0) {
    if (is.null(live_support_bundle) || !"zipcode" %in% names(live_support_bundle) || !(column %in% names(live_support_bundle))) {
      return(stats::setNames(numeric(0), character(0)))
    }
    vals <- suppressWarnings(as.numeric(live_support_bundle[[column]]))
    vals[!is.finite(vals)] <- default
    stats::setNames(vals, as.character(live_support_bundle$zipcode))
  }

  support_named_character <- function(column, default = NA_character_) {
    if (is.null(live_support_bundle) || !"zipcode" %in% names(live_support_bundle) || !(column %in% names(live_support_bundle))) {
      return(stats::setNames(character(0), character(0)))
    }
    vals <- as.character(live_support_bundle[[column]])
    vals[!nzchar(trimws(vals))] <- default
    stats::setNames(vals, as.character(live_support_bundle$zipcode))
  }

  persist_bundle_progress <- function(completed_steps = NA_real_, state = "partial", force_complete = FALSE) {
    if (!isTRUE(persist_partial) || is.null(snapshot_path) || !nzchar(snapshot_path)) return(invisible(NULL))
    bundle_cols <- intersect(external_risk_bundle_columns(), names(zips))
    bundle <- sf::st_drop_geometry(zips[, bundle_cols, drop = FALSE])
    complete_flag <- isTRUE(force_complete) || (is.finite(completed_steps) && completed_steps >= total_steps)
    save_external_bundle_snapshot(
      snapshot_path,
      bundle = bundle,
      complete = complete_flag,
      completed_steps = completed_steps,
      total_steps = total_steps,
      state = if (isTRUE(complete_flag)) "complete" else state
    )
    rm(bundle)
    invisible(release_runtime_memory())
  }

  begin_external_step <- function(label) {
    if (!length(active_steps)) return(0L)
    progress_index <<- progress_index + 1L
    notify_progress(
      progress,
      value = progress_start + (progress_end - progress_start) * ((progress_index - 1L) / length(active_steps)),
      detail = sprintf("Loading %s.", label)
    )
    progress_index
  }

  update_external_band_progress <- function(step_idx, label, band_idx) {
    if (!length(active_steps) || !is.finite(step_idx) || step_idx <= 0) return(invisible(NULL))
    frac <- ((step_idx - 1L) + (band_idx / total_bands)) / length(active_steps)
    notify_progress(
      progress,
      value = progress_start + (progress_end - progress_start) * frac,
      detail = sprintf("Processing %s band %d of %d from north to south.", label, band_idx, total_bands)
    )
    invisible(NULL)
  }

  # Precompute polygon-vs-zips scores once for ALL 861 ZIPs, then per-band
  # callers just slice the result. Each module previously called this same
  # routine 10 times (once per latitude band) against the SAME polygon set;
  # cutting that to one intersection per (feature, polygon-set) eliminates
  # ~90% of the spatial work in the per-band loop.
  precompute_polygon_metric <- function(sf_obj, value_fun) {
    scores <- rep(0, nrow(zips))
    if (is.null(sf_obj) || nrow(sf_obj) == 0) return(scores)
    sf_obj <- repair_external_sf(sf_obj)
    if (nrow(sf_obj) == 0) return(scores)
    match_idx <- match(as.character(zips$zipcode), as.character(wi_zctas$zipcode))
    zip_points <- if (all(is.finite(match_idx))) {
      wi_zip_points[match_idx, , drop = FALSE]
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
  # Backward-compatible per-band wrapper: precomputes once-per-call and slices.
  # Call sites that loop over bands should call precompute_polygon_metric ONCE
  # before the band loop and slice with `[idx]` directly to avoid redundant
  # full passes; this wrapper keeps the old call shape working.
  assign_polygon_metric_band <- function(row_idx, sf_obj, value_fun) {
    if (length(row_idx) == 0L) return(numeric(0))
    if (is.null(sf_obj) || nrow(sf_obj) == 0) return(rep(0, length(row_idx)))
    full <- precompute_polygon_metric(sf_obj, value_fun)
    full[row_idx]
  }

  band_lat_lookup_numeric <- function(named_values, default = 0, step_idx = 0L, label = "") {
    out <- rep(default, nrow(zips))
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      vals <- suppressWarnings(as.numeric(named_values[as.character(zips$lat_band[idx])]))
      vals[!is.finite(vals)] <- default
      out[idx] <- vals
      update_external_band_progress(step_idx, label, band_idx)
      release_runtime_memory()
    }
    out
  }

  flood_entry <- module_entry("flood_guidance")
  if (isTRUE(flood_entry$active)) {
    step_idx <- begin_external_step(flood_entry$label)
    qpf_sf <- get_wpc_qpf_sf(horizon_key)
    flood_sf <- get_wpc_flood_outlook_sf()
    if (isTRUE(requirements$needs_full_flood_detail)) {
      fho_sf <- get_owp_fho_sf(horizon_key)
      nwps_context <- fetch_nwps_gauge_context()
      horizon_river <- select_nwps_horizon_signal(nwps_context, horizon_key = horizon_key)
      corridor_river <- compute_nwps_corridor_signal(horizon_key = horizon_key, nwps_context = nwps_context)
      ffg_scores <- if (identical(horizon_key %||% "live", "live")) fetch_ffg_zip_sensitivity() else support_named_numeric("ffg_live_sensitivity_score", default = 0)
    }
    # Precompute polygon-vs-zips intersections ONCE per feature (before the band
    # loop). The band loop then slices the precomputed vector instead of doing a
    # fresh st_intersects per band.
    qpf_full <- precompute_polygon_metric(qpf_sf, qpf_value_from_row)
    flood_full <- precompute_polygon_metric(flood_sf, flood_outlook_value_from_row)
    fho_full <- if (isTRUE(requirements$needs_full_flood_detail))
      precompute_polygon_metric(fho_sf, fho_value_from_row) else rep(0, nrow(zips))
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      zips$qpf_risk_score[idx] <- qpf_full[idx]
      zips$river_outlook_score[idx] <- flood_full[idx]
      if (isTRUE(requirements$needs_full_flood_detail)) {
        zips$nwm_flood_outlook_score[idx] <- fho_full[idx]
        obs_vals <- suppressWarnings(as.numeric((nwps_context$observed_scores %||% stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode))[as.character(zips$zipcode[idx])]))
        fc_vals <- suppressWarnings(as.numeric((nwps_context$forecast_scores %||% stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode))[as.character(zips$zipcode[idx])]))
        nwm_vals <- suppressWarnings(as.numeric((nwps_context$nwm_scores %||% stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode))[as.character(zips$zipcode[idx])]))
        obs_vals[!is.finite(obs_vals)] <- 0
        fc_vals[!is.finite(fc_vals)] <- 0
        nwm_vals[!is.finite(nwm_vals)] <- 0
        zips$river_gauge_observed_score[idx] <- obs_vals
        zips$river_gauge_forecast_score[idx] <- fc_vals
        zips$river_gauge_nwm_score[idx] <- nwm_vals
        point_vals <- suppressWarnings(as.numeric((horizon_river$scores %||% numeric(0))[as.character(zips$zipcode[idx])]))
        point_vals[!is.finite(point_vals)] <- 0
        zips$river_gauge_point_score[idx] <- point_vals
        zips$river_gauge_point_reason_text[idx] <- as.character((horizon_river$labels %||% character(0))[as.character(zips$zipcode[idx])])
        zips$river_gauge_point_source[idx] <- as.character((horizon_river$dominant_source %||% character(0))[as.character(zips$zipcode[idx])])
        corridor_vals <- suppressWarnings(as.numeric((corridor_river$scores %||% numeric(0))[as.character(zips$zipcode[idx])]))
        corridor_vals[!is.finite(corridor_vals)] <- 0
        zips$river_corridor_score[idx] <- corridor_vals
        zips$river_corridor_reason_text[idx] <- as.character((corridor_river$reasons %||% character(0))[as.character(zips$zipcode[idx])])
        zips$river_corridor_source[idx] <- as.character((corridor_river$sources %||% character(0))[as.character(zips$zipcode[idx])])
        zips$river_gauge_score[idx] <- pmax(zips$river_gauge_point_score[idx] %||% 0, 0.85 * (zips$river_corridor_score[idx] %||% 0), na.rm = TRUE)
        zips$river_gauge_reason_text[idx] <- ifelse(
          (zips$river_gauge_point_score[idx] %||% 0) >= 0.85 * (zips$river_corridor_score[idx] %||% 0) & nzchar(trimws(as.character(zips$river_gauge_point_reason_text[idx] %||% ""))),
          as.character(zips$river_gauge_point_reason_text[idx] %||% ""),
          ifelse(
            nzchar(trimws(as.character(zips$river_corridor_reason_text[idx] %||% ""))),
            as.character(zips$river_corridor_reason_text[idx] %||% ""),
            as.character(zips$river_gauge_point_reason_text[idx] %||% "")
          )
        )
        zips$river_gauge_source[idx] <- ifelse(
          (zips$river_gauge_point_score[idx] %||% 0) >= 0.85 * (zips$river_corridor_score[idx] %||% 0),
          as.character(zips$river_gauge_point_source[idx] %||% NA_character_),
          as.character(zips$river_corridor_source[idx] %||% NA_character_)
        )
        band_ffg <- suppressWarnings(as.numeric(ffg_scores[as.character(zips$zipcode[idx])]))
        band_ffg[!is.finite(band_ffg)] <- 0
        zips$ffg_live_sensitivity_score[idx] <- band_ffg
        zips$ffg_total_score[idx] <- if (identical(horizon_key %||% "live", "live")) band_ffg else apply_live_decay(band_ffg, horizon_key, half_life_hours = 18)
      }
      update_external_band_progress(step_idx, flood_entry$label, band_idx)
      release_runtime_memory()
    }
    rm(qpf_sf, flood_sf)
    if (exists("fho_sf", inherits = FALSE)) rm(fho_sf)
    if (exists("nwps_context", inherits = FALSE)) rm(nwps_context)
    if (exists("horizon_river", inherits = FALSE)) rm(horizon_river)
    if (exists("corridor_river", inherits = FALSE)) rm(corridor_river)
    if (exists("ffg_scores", inherits = FALSE)) rm(ffg_scores)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  winter_entry <- module_entry("winter_guidance")
  if (isTRUE(winter_entry$active)) {
    step_idx <- begin_external_step(winter_entry$label)
    winter_sets <- get_wpc_winter_sf(horizon_key)
    snow4_full <- precompute_polygon_metric(winter_sets[["snow4"]], winter_prob_value_from_row)
    snow8_full <- precompute_polygon_metric(winter_sets[["snow8"]], winter_prob_value_from_row)
    snow12_full <- precompute_polygon_metric(winter_sets[["snow12"]], winter_prob_value_from_row)
    ice25_full <- precompute_polygon_metric(winter_sets[["ice25"]], winter_prob_value_from_row)
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      snow4 <- snow4_full[idx]
      snow8 <- snow8_full[idx]
      snow12 <- snow12_full[idx]
      ice25 <- ice25_full[idx]
      zips$winter_risk_score[idx] <- pmin(1, pmax(0.45 * snow4, 0.70 * snow8, 1.00 * snow12, 0.90 * ice25, na.rm = TRUE))
      update_external_band_progress(step_idx, winter_entry$label, band_idx)
      rm(snow4, snow8, snow12, ice25)
      release_runtime_memory()
    }
    rm(winter_sets)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  fire_entry <- module_entry("fire_guidance")
  if (isTRUE(fire_entry$active)) {
    step_idx <- begin_external_step(fire_entry$label)
    fire_sets <- load_spc_fire_sf(horizon_key)
    fire_full_by_layer <- lapply(names(fire_sets), function(nm)
      precompute_polygon_metric(fire_sets[[nm]], fire_value_from_row))
    names(fire_full_by_layer) <- names(fire_sets)
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      fire_scores <- rep(0, length(idx))
      for (nm in names(fire_sets)) {
        fire_scores <- pmax(fire_scores, fire_full_by_layer[[nm]][idx], na.rm = TRUE)
      }
      zips$fire_risk_score[idx] <- fire_scores
      update_external_band_progress(step_idx, fire_entry$label, band_idx)
      rm(fire_scores)
      release_runtime_memory()
    }
    rm(fire_sets)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  convective_entry <- module_entry("convective_guidance")
  if (isTRUE(convective_entry$active)) {
    step_idx <- begin_external_step(convective_entry$label)
    convective_sets <- load_spc_convective_sf(horizon_key)
    convective_full_by_layer <- lapply(names(convective_sets), function(nm)
      precompute_polygon_metric(convective_sets[[nm]], convective_value_from_row))
    names(convective_full_by_layer) <- names(convective_sets)
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      convective_scores <- rep(0, length(idx))
      for (nm in names(convective_sets)) {
        convective_scores <- pmax(convective_scores, convective_full_by_layer[[nm]][idx], na.rm = TRUE)
      }
      zips$convective_guidance_score[idx] <- convective_scores
      update_external_band_progress(step_idx, convective_entry$label, band_idx)
      rm(convective_scores)
      release_runtime_memory()
    }
    rm(convective_sets)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  lightning_entry <- module_entry("convective_lightning")
  if (isTRUE(lightning_entry$active)) {
    step_idx <- begin_external_step(lightning_entry$label)
    if (identical(lightning_entry$mode, "native")) {
      glm_lightning <- fetch_glm_lightning_scores()
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_glm <- suppressWarnings(as.numeric((glm_lightning$scores %||% numeric(0))[as.character(zips$zipcode[idx])]))
        band_glm[!is.finite(band_glm)] <- 0
        zips$glm_lightning_live_score[idx] <- band_glm
        zips$glm_lightning_reason_text[idx] <- as.character((glm_lightning$labels %||% character(0))[as.character(zips$zipcode[idx])])
        zips$glm_lightning_total_score[idx] <- if (identical(horizon_key %||% "live", "live")) band_glm else apply_live_decay(band_glm, horizon_key, half_life_hours = if (is.finite(lightning_entry$half_life_hours)) lightning_entry$half_life_hours else 3)
        update_external_band_progress(step_idx, lightning_entry$label, band_idx)
        rm(band_glm)
        release_runtime_memory()
      }
      rm(glm_lightning)
    } else {
      lightning_scores <- support_named_numeric("glm_lightning_live_score", default = 0)
      lightning_reasons <- support_named_character("glm_lightning_reason_text", default = NA_character_)
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_glm <- suppressWarnings(as.numeric(lightning_scores[as.character(zips$zipcode[idx])]))
        band_glm[!is.finite(band_glm)] <- 0
        band_reasons <- as.character(lightning_reasons[as.character(zips$zipcode[idx])])
        band_reasons[!nzchar(trimws(band_reasons))] <- NA_character_
        zips$glm_lightning_live_score[idx] <- band_glm
        zips$glm_lightning_reason_text[idx] <- band_reasons
        zips$glm_lightning_total_score[idx] <- apply_live_decay(band_glm, horizon_key, half_life_hours = if (is.finite(lightning_entry$half_life_hours)) lightning_entry$half_life_hours else 3)
        update_external_band_progress(step_idx, lightning_entry$label, band_idx)
        rm(band_glm, band_reasons)
        release_runtime_memory()
      }
    }
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  heat_entry <- module_entry("heat_guidance")
  if (isTRUE(heat_entry$active)) {
    step_idx <- begin_external_step(heat_entry$label)
    heatrisk_sf <- get_heatrisk_sf(horizon_key)
    heatrisk_full <- precompute_polygon_metric(heatrisk_sf, heatrisk_value_from_row)
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      zips$heatrisk_official_score[idx] <- heatrisk_full[idx]
      update_external_band_progress(step_idx, heat_entry$label, band_idx)
      release_runtime_memory()
    }
    rm(heatrisk_sf)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  uv_entry <- module_entry("uv_guidance")
  if (isTRUE(uv_entry$active)) {
    step_idx <- begin_external_step(uv_entry$label)
    uv_lookup <- fetch_uv_band_scores()
    zips$uv_live_score <- band_lat_lookup_numeric(uv_lookup, default = 0, step_idx = step_idx, label = uv_entry$label)
    zips$uv_total_score <- if (identical(horizon_key %||% "live", "live")) zips$uv_live_score else apply_live_decay(zips$uv_live_score, horizon_key, half_life_hours = 24)
    rm(uv_lookup)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  radmon_entry <- module_entry("radiation_monitor")
  if (isTRUE(radmon_entry$active)) {
    step_idx <- begin_external_step(radmon_entry$label)
    if (identical(radmon_entry$mode, "native")) {
      radnet_data <- fetch_radnet_wi_scores()
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_radnet <- suppressWarnings(as.numeric((radnet_data$scores %||% numeric(0))[as.character(zips$zipcode[idx])]))
        band_radnet[!is.finite(band_radnet)] <- 0
        zips$radnet_live_score[idx] <- band_radnet
        zips$radnet_reason_text[idx] <- as.character((radnet_data$labels %||% character(0))[as.character(zips$zipcode[idx])])
        zips$radnet_total_score[idx] <- if (identical(horizon_key %||% "live", "live")) band_radnet else apply_live_decay(band_radnet, horizon_key, half_life_hours = if (is.finite(radmon_entry$half_life_hours)) radmon_entry$half_life_hours else 36)
        update_external_band_progress(step_idx, radmon_entry$label, band_idx)
        rm(band_radnet)
        release_runtime_memory()
      }
      rm(radnet_data)
    } else {
      radnet_scores <- support_named_numeric("radnet_live_score", default = 0)
      radnet_reasons <- support_named_character("radnet_reason_text", default = NA_character_)
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_radnet <- suppressWarnings(as.numeric(radnet_scores[as.character(zips$zipcode[idx])]))
        band_radnet[!is.finite(band_radnet)] <- 0
        band_reasons <- as.character(radnet_reasons[as.character(zips$zipcode[idx])])
        band_reasons[!nzchar(trimws(band_reasons))] <- NA_character_
        zips$radnet_live_score[idx] <- band_radnet
        zips$radnet_reason_text[idx] <- band_reasons
        zips$radnet_total_score[idx] <- apply_live_decay(band_radnet, horizon_key, half_life_hours = if (is.finite(radmon_entry$half_life_hours)) radmon_entry$half_life_hours else 36)
        update_external_band_progress(step_idx, radmon_entry$label, band_idx)
        rm(band_radnet, band_reasons)
        release_runtime_memory()
      }
    }
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  nrc_entry <- module_entry("radiation_incident")
  if (isTRUE(nrc_entry$active)) {
    step_idx <- begin_external_step(nrc_entry$label)
    if (identical(nrc_entry$mode, "native")) {
      nrc_signal <- fetch_nrc_radiation_signal()
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_nrc <- rep(nrc_signal$score %||% 0, length(idx))
        zips$nrc_live_score[idx] <- band_nrc
        zips$nrc_total_score[idx] <- if (identical(horizon_key %||% "live", "live")) band_nrc else apply_live_decay(band_nrc, horizon_key, half_life_hours = if (is.finite(nrc_entry$half_life_hours)) nrc_entry$half_life_hours else 72)
        zips$nrc_event_text[idx] <- rep(nrc_signal$label %||% NA_character_, length(idx))
        update_external_band_progress(step_idx, nrc_entry$label, band_idx)
        rm(band_nrc)
        release_runtime_memory()
      }
      rm(nrc_signal)
    } else {
      nrc_scores <- support_named_numeric("nrc_live_score", default = 0)
      nrc_labels <- support_named_character("nrc_event_text", default = NA_character_)
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_nrc <- suppressWarnings(as.numeric(nrc_scores[as.character(zips$zipcode[idx])]))
        band_nrc[!is.finite(band_nrc)] <- 0
        band_labels <- as.character(nrc_labels[as.character(zips$zipcode[idx])])
        band_labels[!nzchar(trimws(band_labels))] <- NA_character_
        zips$nrc_live_score[idx] <- band_nrc
        zips$nrc_total_score[idx] <- apply_live_decay(band_nrc, horizon_key, half_life_hours = if (is.finite(nrc_entry$half_life_hours)) nrc_entry$half_life_hours else 72)
        zips$nrc_event_text[idx] <- band_labels
        update_external_band_progress(step_idx, nrc_entry$label, band_idx)
        rm(band_nrc, band_labels)
        release_runtime_memory()
      }
    }
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  seismic_entry <- module_entry("seismic_guidance")
  if (isTRUE(seismic_entry$active)) {
    step_idx <- begin_external_step(seismic_entry$label)
    if (identical(seismic_entry$mode, "native")) {
      seismic_data <- fetch_usgs_seismic_scores()
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_seismic <- suppressWarnings(as.numeric((seismic_data$scores %||% numeric(0))[as.character(zips$zipcode[idx])]))
        band_seismic[!is.finite(band_seismic)] <- 0
        zips$seismic_live_score[idx] <- band_seismic
        zips$seismic_event_text[idx] <- as.character((seismic_data$labels %||% character(0))[as.character(zips$zipcode[idx])])
        seismic_base_signal <- if (identical(horizon_key %||% "live", "live")) band_seismic else apply_live_decay(band_seismic, horizon_key, half_life_hours = if (is.finite(seismic_entry$half_life_hours)) seismic_entry$half_life_hours else 48)
        zips$seismic_total_score[idx] <- pmin(1, blend_alert_signal(seismic_base_signal, zips$seismic_alert_score[idx] %||% 0, event = zips$alert_event[idx] %||% rep("", length(idx)), alert_weight = 0.92))
        update_external_band_progress(step_idx, seismic_entry$label, band_idx)
        rm(band_seismic, seismic_base_signal)
        release_runtime_memory()
      }
      rm(seismic_data)
    } else {
      seismic_scores <- support_named_numeric("seismic_live_score", default = 0)
      seismic_labels <- support_named_character("seismic_event_text", default = NA_character_)
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_seismic <- suppressWarnings(as.numeric(seismic_scores[as.character(zips$zipcode[idx])]))
        band_seismic[!is.finite(band_seismic)] <- 0
        band_labels <- as.character(seismic_labels[as.character(zips$zipcode[idx])])
        band_labels[!nzchar(trimws(band_labels))] <- NA_character_
        zips$seismic_live_score[idx] <- band_seismic
        zips$seismic_event_text[idx] <- band_labels
        seismic_base_signal <- apply_live_decay(band_seismic, horizon_key, half_life_hours = if (is.finite(seismic_entry$half_life_hours)) seismic_entry$half_life_hours else 48)
        zips$seismic_total_score[idx] <- pmin(1, blend_alert_signal(seismic_base_signal, zips$seismic_alert_score[idx] %||% 0, event = zips$alert_event[idx] %||% rep("", length(idx)), alert_weight = 0.92))
        update_external_band_progress(step_idx, seismic_entry$label, band_idx)
        rm(band_seismic, band_labels, seismic_base_signal)
        release_runtime_memory()
      }
    }
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  air_entry <- module_entry("air_guidance")
  if (isTRUE(air_entry$active)) {
    step_idx <- begin_external_step(air_entry$label)
    airnow_live_scores <- if (identical(horizon_key %||% "live", "live")) fetch_airnow_live_scores() else support_named_numeric("airnow_live_score", default = 0)
    airnow_scores <- fetch_airnow_scores(horizon_key)
    for (band_idx in seq_along(band_groups)) {
      idx <- band_groups[[band_idx]]
      if (length(idx) == 0) next
      band_live <- suppressWarnings(as.numeric(airnow_live_scores[as.character(zips$zipcode[idx])]))
      band_live[!is.finite(band_live)] <- 0
      band_total <- suppressWarnings(as.numeric(airnow_scores[as.character(zips$zipcode[idx])]))
      band_total[!is.finite(band_total)] <- 0
      zips$airnow_live_score[idx] <- band_live
      zips$airnow_total_score[idx] <- band_total
      update_external_band_progress(step_idx, air_entry$label, band_idx)
      rm(band_live, band_total)
      release_runtime_memory()
    }
    rm(airnow_live_scores, airnow_scores)
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  transport_entry <- module_entry("transport_guidance")
  if (isTRUE(transport_entry$active)) {
    step_idx <- begin_external_step(transport_entry$label)
    if (identical(transport_entry$mode, "native")) {
      wi511_transport <- compute_511_zip_transport_risk(horizon_key)
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_transport <- suppressWarnings(as.numeric((wi511_transport$scores %||% numeric(0))[as.character(zips$zipcode[idx])]))
        band_transport[!is.finite(band_transport)] <- 0
        zips$wi511_transport_score[idx] <- band_transport
        zips$wi511_transport_reason[idx] <- as.character((wi511_transport$reasons %||% character(0))[as.character(zips$zipcode[idx])])
        update_external_band_progress(step_idx, transport_entry$label, band_idx)
        rm(band_transport)
        release_runtime_memory()
      }
      rm(wi511_transport)
    } else {
      transport_scores <- support_named_numeric("wi511_transport_score", default = 0)
      transport_reasons <- support_named_character("wi511_transport_reason", default = NA_character_)
      for (band_idx in seq_along(band_groups)) {
        idx <- band_groups[[band_idx]]
        if (length(idx) == 0) next
        band_transport <- suppressWarnings(as.numeric(transport_scores[as.character(zips$zipcode[idx])]))
        band_transport[!is.finite(band_transport)] <- 0
        band_reasons <- as.character(transport_reasons[as.character(zips$zipcode[idx])])
        band_reasons[!nzchar(trimws(band_reasons))] <- NA_character_
        zips$wi511_transport_score[idx] <- apply_live_decay(band_transport, horizon_key, half_life_hours = if (is.finite(transport_entry$half_life_hours)) transport_entry$half_life_hours else 12)
        zips$wi511_transport_reason[idx] <- band_reasons
        update_external_band_progress(step_idx, transport_entry$label, band_idx)
        rm(band_transport, band_reasons)
        release_runtime_memory()
      }
    }
    release_runtime_memory()
    persist_bundle_progress(progress_index, state = "partial")
  }

  zips$heat_risk_score <- ifelse(is.finite(zips$forecast_temperature_f), vector_piecewise_score(zips$forecast_temperature_f, 85, 95, 105), 0)
  zips$cold_risk_score <- ifelse(is.finite(zips$forecast_temperature_f), vector_piecewise_score(pmax(0, 40 - zips$forecast_temperature_f), 8, 20, 35), 0)
  persist_bundle_progress(total_steps, state = "complete", force_complete = TRUE)
  zips
}

# Returns the canonical character vector of column names that an external bundle data.frame produces (zipcode + every per-hazard score/text column).
external_risk_bundle_columns <- function() {
  c(
    "zipcode",
    "qpf_risk_score", "winter_risk_score", "river_outlook_score", "nwm_flood_outlook_score",
    "fire_risk_score", "convective_guidance_score", "glm_lightning_live_score",
    "glm_lightning_reason_text", "glm_lightning_total_score", "heatrisk_official_score",
    "river_gauge_observed_score", "river_gauge_forecast_score", "river_gauge_nwm_score",
    "river_gauge_point_score", "river_gauge_point_reason_text", "river_gauge_point_source",
    "river_corridor_score", "river_corridor_reason_text", "river_corridor_source",
    "river_gauge_score", "river_gauge_reason_text", "river_gauge_source",
    "ffg_live_sensitivity_score", "ffg_total_score",
    "uv_live_score", "uv_total_score",
    "radnet_live_score", "radnet_reason_text", "radnet_total_score",
    "nrc_live_score", "nrc_total_score", "nrc_event_text",
    "seismic_live_score", "seismic_event_text", "seismic_total_score",
    "airnow_live_score", "airnow_total_score",
    "wi511_transport_score", "wi511_transport_reason",
    "heat_risk_score", "cold_risk_score"
  )
}

# Why: the bundle build is incremental, so the zip frame must start with
# every column at a sane default before partial fills overlay it.
# What: returns zips with all bundle columns initialised (numeric -> 0,
# character -> NA), plus computed heat_risk_score and cold_risk_score.
# How: assigns rep(0, n) / rep(NA, n) per known column, then fills heat/
# cold from forecast_temperature_f via piecewise_score (heat 85/95/105,
# cold thresholds applied to (40 - temp)).
# When: called by apply_external_risk_bundle and inside compute_external_risk_bundle
# at the top of every build.
# Impact: a missing column here propagates as "NULL" reads downstream;
# extending the bundle requires both this function and external_risk_bundle_columns.
initialize_external_risk_columns <- function(zips) {
  zero_num <- rep(0, nrow(zips))
  na_chr <- rep(NA_character_, nrow(zips))
  zips$qpf_risk_score <- zero_num
  zips$winter_risk_score <- zero_num
  zips$river_outlook_score <- zero_num
  zips$nwm_flood_outlook_score <- zero_num
  zips$fire_risk_score <- zero_num
  zips$convective_guidance_score <- zero_num
  zips$glm_lightning_live_score <- zero_num
  zips$glm_lightning_reason_text <- na_chr
  zips$glm_lightning_total_score <- zero_num
  zips$heatrisk_official_score <- zero_num
  zips$river_gauge_observed_score <- zero_num
  zips$river_gauge_forecast_score <- zero_num
  zips$river_gauge_nwm_score <- zero_num
  zips$river_gauge_point_score <- zero_num
  zips$river_gauge_point_reason_text <- na_chr
  zips$river_gauge_point_source <- na_chr
  zips$river_corridor_score <- zero_num
  zips$river_corridor_reason_text <- na_chr
  zips$river_corridor_source <- na_chr
  zips$river_gauge_score <- zero_num
  zips$river_gauge_reason_text <- na_chr
  zips$river_gauge_source <- na_chr
  zips$ffg_live_sensitivity_score <- zero_num
  zips$ffg_total_score <- zero_num
  zips$uv_live_score <- zero_num
  zips$uv_total_score <- zero_num
  zips$radnet_live_score <- zero_num
  zips$radnet_reason_text <- na_chr
  zips$radnet_total_score <- zero_num
  zips$nrc_live_score <- zero_num
  zips$nrc_total_score <- zero_num
  zips$nrc_event_text <- na_chr
  zips$seismic_live_score <- zero_num
  zips$seismic_event_text <- na_chr
  zips$seismic_total_score <- zero_num
  zips$airnow_live_score <- zero_num
  zips$airnow_total_score <- zero_num
  zips$wi511_transport_score <- zero_num
  zips$wi511_transport_reason <- na_chr
  zips$heat_risk_score <- ifelse(is.finite(zips$forecast_temperature_f), vector_piecewise_score(zips$forecast_temperature_f, 85, 95, 105), 0)
  zips$cold_risk_score <- ifelse(is.finite(zips$forecast_temperature_f), vector_piecewise_score(pmax(0, 40 - zips$forecast_temperature_f), 8, 20, 35), 0)
  zips
}

# Why: cached bundle data needs to be merged back into the live zips frame
# without losing the canonical defaults from initialize_external_risk_columns.
# What: returns zips with bundle columns overlaid by zipcode match; rows
# that do not match in bundle keep their initialised defaults.
# How: starts with initialize_external_risk_columns, then for every
# overlapping column copies bundle$col[match(zipcode)] in.
# When: called by load_external_risk_bundle to apply whatever was loaded
# from cache/snapshot.
# Impact: a column rename in bundle vs columns() definition silently leaves
# a hazard at default until both sides are updated.
apply_external_risk_bundle <- function(zips, bundle = NULL) {
  zips <- initialize_external_risk_columns(zips)
  if (is.null(bundle) || !nrow(bundle)) return(zips)
  idx <- match(zips$zipcode, bundle$zipcode)
  if (!any(!is.na(idx))) return(zips)
  for (col in setdiff(intersect(names(bundle), external_risk_bundle_columns()), "zipcode")) {
    zips[[col]] <- bundle[[col]][idx]
  }
  zips
}

# Why: orchestrate the stale-while-revalidate policy for the bundle so the
# UI never blocks on a cold rebuild unless force_sync is set.
# What: returns list(bundle, state) where state describes how the bundle
# was sourced: "cache"/"snapshot"/"partial"/"stale"/"stale-partial"/
# "queued"/"sync".
# How: tries cache_get -> fresh snapshot -> stale snapshot -> queue an
# async warmer; only computes synchronously when force_sync is TRUE.
# When: called by enrich_external_risks at the top of the per-build pass.
# Impact: changing the precedence here changes which "freshness tier" the
# user sees first, and whether the warmer fires at the right moment.
load_external_risk_bundle <- function(zips, horizon_key = "live", selected_features = FAST_START_FEATURES, include_transport = FALSE, progress = NULL, progress_span = c(0.35, 0.78), allow_stale = TRUE, schedule_refresh = TRUE, force_sync = FALSE, project_dir = getwd()) {
  cache_name <- external_bundle_cache_name(horizon_key, selected_features, include_transport = include_transport)
  fresh_age <- external_bundle_fresh_age_seconds(horizon_key)
  stale_age <- external_bundle_stale_age_seconds(horizon_key)
  snap_path <- external_bundle_snapshot_path(horizon_key, selected_features, include_transport = include_transport)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(list(bundle = cached, state = "cache"))

  persisted_info <- load_external_bundle_snapshot(snap_path, max_age_seconds = fresh_age)
  if (!is.null(persisted_info)) {
    persisted_ttl <- if (isTRUE(persisted_info$complete)) fresh_age else max(60L, min(300L, fresh_age %/% 4L))
    cache_put("derived", cache_name, persisted_info$bundle, ttl_seconds = persisted_ttl)
    if (isTRUE(persisted_info$complete)) {
      return(list(bundle = persisted_info$bundle, state = "snapshot"))
    }
    if (isTRUE(schedule_refresh) && !external_bundle_warmer_active(horizon_key, selected_features, include_transport = include_transport)) {
      schedule_external_risk_bundle_prefetch(horizon_key, selected_features = selected_features, include_transport = include_transport, project_dir = project_dir, force = FALSE)
    }
    notify_progress(progress, progress_span[1] %||% 0.35, "Using staged external guidance while remaining layers continue refreshing in the background.")
    return(list(bundle = persisted_info$bundle, state = "partial"))
  }

  stale_info <- if (isTRUE(allow_stale)) load_external_bundle_snapshot(snap_path, max_age_seconds = stale_age) else NULL
  if (!is.null(stale_info)) {
    cache_put("derived", cache_name, stale_info$bundle, ttl_seconds = max(60L, min(300L, fresh_age %/% 4L)))
    if (isTRUE(schedule_refresh)) {
      schedule_external_risk_bundle_prefetch(horizon_key, selected_features = selected_features, include_transport = include_transport, project_dir = project_dir, force = FALSE)
    }
    notify_progress(progress, progress_span[1] %||% 0.35, if (isTRUE(stale_info$complete)) "Using cached external guidance while refreshing live layers in the background." else "Using cached staged external guidance while refreshing remaining live layers in the background.")
    return(list(bundle = stale_info$bundle, state = if (isTRUE(stale_info$complete)) "stale" else "stale-partial"))
  }

  if (!isTRUE(force_sync)) {
    if (isTRUE(schedule_refresh)) {
      schedule_external_risk_bundle_prefetch(horizon_key, selected_features = selected_features, include_transport = include_transport, project_dir = project_dir, force = FALSE)
    }
    notify_progress(progress, progress_span[1] %||% 0.35, "Loading baseline map now and refreshing external guidance in the background.")
    return(list(bundle = NULL, state = "queued"))
  }

  bundle_zips <- compute_external_risk_bundle(
    zips,
    horizon_key = horizon_key,
    selected_features = selected_features,
    include_transport = include_transport,
    progress = progress,
    progress_span = progress_span,
    snapshot_path = snap_path,
    persist_partial = TRUE
  )
  bundle_cols <- intersect(external_risk_bundle_columns(), names(bundle_zips))
  bundle <- sf::st_drop_geometry(bundle_zips[, bundle_cols, drop = FALSE])
  invalidate_replaced_live_payloads("derived", prefix = paste0("external-bundle-", horizon_key, "-"), keep_key = cache_name)
  cache_put("derived", cache_name, bundle, ttl_seconds = fresh_age)
  save_external_bundle_snapshot(snap_path, bundle, complete = TRUE, completed_steps = Inf, total_steps = Inf, state = "complete")
  # Time-horizon decoupling: now that we paid the cold-build cost for one
  # horizon, the underlying fetcher caches are hot. Schedule background
  # warmers for the OTHER horizons so the user never sees lag on their
  # first click of a sibling horizon. The warmers run in separate Rscript
  # processes, so this is non-blocking for the caller.
  if (isTRUE(schedule_refresh)) {
    sibling_horizons <- setdiff(c("live", "24h", "48h", "72h"), horizon_key)
    for (sibling in sibling_horizons) {
      sibling_cache <- external_bundle_cache_name(sibling, selected_features, include_transport = include_transport)
      if (is.null(cache_get("derived", sibling_cache)) &&
          !external_bundle_warmer_active(sibling, selected_features, include_transport = include_transport)) {
        schedule_external_risk_bundle_prefetch(
          sibling,
          selected_features = selected_features,
          include_transport = include_transport,
          project_dir = project_dir,
          force = FALSE
        )
      }
    }
  }
  release_runtime_memory(full = TRUE)
  list(bundle = bundle, state = "sync")
}

# Why: single public entry-point that loads the bundle and applies it onto
# zips, exposing the bundle "state" via attribute for downstream gating.
# What: returns zips merged with the bundle columns; sets
# attr(., "external_bundle_state") to the source state string.
# How: load_external_risk_bundle -> apply_external_risk_bundle, attaching
# the state attribute.
# When: called from the layer build pipeline whenever a horizon's bundle
# data is needed.
# Impact: callers read the attribute to decide whether to display a "data
# refreshing" banner; missing it would hide the staleness signal.
enrich_external_risks <- function(zips, horizon_key = "live", selected_features = FAST_START_FEATURES, include_transport = FALSE, progress = NULL, progress_span = c(0.35, 0.78), allow_stale = TRUE, schedule_refresh = TRUE, force_sync = FALSE, project_dir = getwd()) {
  bundle_info <- load_external_risk_bundle(
    zips,
    horizon_key = horizon_key,
    selected_features = selected_features,
    include_transport = include_transport,
    progress = progress,
    progress_span = progress_span,
    allow_stale = allow_stale,
    schedule_refresh = schedule_refresh,
    force_sync = force_sync,
    project_dir = project_dir
  )
  out <- apply_external_risk_bundle(zips, bundle_info$bundle)
  attr(out, "external_bundle_state") <- bundle_info$state %||% "unknown"
  out
}
