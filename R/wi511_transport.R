# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_transport.R - top-level 511WI assemblers:
# build_511_roads_overlay (visual road overlay = winter + events,
# snapped + styled) and compute_511_zip_transport_risk (per-ZIP
# transport risk + reason text fused from official overlay
# proximity, message-sign signal, alerts).


# Why: produce the unified WI511 road-overlay sf by combining winter and
# events feeds with consistent styling.
# What: returns an sf with road_color/opacity/weight/popup_label etc., or
# empty_road_overlay_sf when no rows.
# How: rbinds standardize_road_overlay_sf(winter/events), snaps each row
# to the nearest matching OSM road, then styles uniformly via
# risk_rgb_hex; caches under wi511-roads-overlay-<horizon>.
# When: called by build_driving_roads_overlay just before merging with
# modeled road risk.
# Impact: the source-of-truth for the WI511 overlay - any new feed needs
# to be added here and to standardize_road_overlay_sf's column list.
build_511_roads_overlay <- function(horizon_key = "live", progress = NULL) {
  cache_name <- paste0("wi511-roads-overlay-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  # Travel-time delay is a congestion signal, not a safety hazard, so
  # it's deliberately excluded from the risk overlay. Only winter and
  # events feed the overlay. mclapply forks one worker per feed.
  fetchers <- list(winter = fetch_511_winter_roads_live,
                   events = fetch_511_events_live)
  use_parallel <- .Platform$OS.type != "windows"
  results <- if (use_parallel) {
    parallel::mclapply(fetchers, function(fn) safely(fn()),
                       mc.cores = length(fetchers), mc.preschedule = FALSE)
  } else {
    lapply(fetchers, function(fn) safely(fn()))
  }
  winter <- results$winter
  events <- results$events
  out <- tryCatch(suppressWarnings(rbind(standardize_road_overlay_sf(winter), standardize_road_overlay_sf(events))), error = function(e) empty_road_overlay_sf())
  if (nrow(out) == 0) {
    ttl <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
    cache_put("derived", cache_name, out, ttl_seconds = ttl)
    return(out)
  }
  out <- repair_external_sf(out)
  if (nrow(out) == 0) {
    ttl <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
    cache_put("derived", cache_name, out, ttl_seconds = ttl)
    return(out)
  }
  # Snap each 511 row to the nearest matching OSM trace before styling so
  # the rendered overlay follows the road instead of cutting a straight
  # diagonal between the API's start/end points.
  out <- tryCatch(
    snap_511_overlay_to_osm_roads(out, progress = progress),
    error = function(e) out
  )
  if (!identical(horizon_key, "live")) {
    out$driving_total_risk <- apply_live_decay(out$driving_total_risk, horizon_key, half_life_hours = 12)
    out$driving_reason_text <- paste0(out$driving_reason_text, " Live roadway feed decayed for the selected forecast horizon.")
  }
  out$road_color <- risk_rgb_hex(out$driving_total_risk)
  out$road_opacity <- ifelse((out$driving_total_risk %||% 0) >= RISK_GREEN_MIN, 0.50, 0)
  out$road_weight <- ifelse(out$road_class == "511WI winter", 5.4, ifelse(out$road_class == "511WI event", 5.2, 4.8))
  out$driving_risk_label <- risk_label_from_score(out$driving_total_risk)
  ttl <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
  cache_put("derived", cache_name, out, ttl_seconds = ttl)
  out
}


# Why: top-level WI511 ZIP-level risk that fuses official road overlay,
# message signs, and prose alerts into one (score, reason) pair per ZIP.
# What: returns list(scores, reasons) keyed by zipcode; reasons reflect the
# winning source per ZIP.
# How: starts from official-overlay proximity (within 22km, 9km decay),
# overlays sign signal where higher, overlays alert signal where higher,
# caches.
# When: called per horizon by the WI511 transport pipeline.
# Impact: this is the per-ZIP "transport risk" surface used in driving
# scoring; ordering of overlays here decides which source wins ties.
compute_511_zip_transport_risk <- function(horizon_key = "live") {
  key <- paste0("wi511-zip-transport-", horizon_key)
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  official <- build_511_roads_overlay(horizon_key)
  if (nrow(official) > 0) {
    official <- repair_external_sf(official)
    zip_pts_proj <- wi_zip_points_proj
    official_proj <- suppressWarnings(sf::st_transform(official, 5070))
    poly_hits <- safe_st_intersects(wi_zctas, official)
    prox_hits <- suppressWarnings(sf::st_is_within_distance(zip_pts_proj, official_proj, dist = 22000))
    # Bulk distance matrix replaces 861 per-ZIP st_distance calls. With
    # the noise filter trimming 511 to ~50 rows, this is a tiny
    # ~50k-cell matrix.
    d_full <- suppressWarnings(sf::st_distance(zip_pts_proj, official_proj))
    d_full <- matrix(as.numeric(d_full), nrow = nrow(zip_pts_proj))
    d_full[!is.finite(d_full)] <- 22000
    official_risk <- safe_numeric(official$driving_total_risk %||% 0)
    official_risk[!is.finite(official_risk)] <- 0
    official_reason <- as.character(official$driving_reason_text %||% rep("", nrow(official)))
    official_source <- as.character(official$road_source %||% rep("", nrow(official)))
    for (i in seq_along(out_scores)) {
      idx <- unique(c(as.integer(poly_hits[[i]]), as.integer(prox_hits[[i]])))
      idx <- idx[is.finite(idx)]
      if (length(idx) == 0) next
      vals <- official_risk[idx]
      if (!any(vals > 0)) next
      d <- d_full[i, idx]
      intersect_idx <- as.integer(poly_hits[[i]])
      if (length(intersect_idx) > 0) {
        pos <- match(intersect_idx, idx, nomatch = 0)
        pos <- pos[pos > 0]
        if (length(pos) > 0) d[pos] <- 0
      }
      local_scores <- pmin(1, vals * exp(-pmax(d, 0) / 9000))
      best_local <- which.max(local_scores)[1]
      out_scores[i] <- local_scores[best_local]
      best_global <- idx[best_local]
      r <- official_reason[best_global]
      if (!nzchar(r)) r <- official_source[best_global]
      out_reasons[i] <- if (!nzchar(r)) NA_character_ else r
    }
  }
  sign_signal <- compute_511_message_sign_zip_signal(horizon_key)
  sign_scores <- unname(sign_signal$scores[wi_zctas$zipcode])
  sign_reasons <- unname(sign_signal$reasons[wi_zctas$zipcode])
  sign_scores[!is.finite(sign_scores)] <- 0
  use_sign <- sign_scores > out_scores
  out_scores[use_sign] <- sign_scores[use_sign]
  out_reasons[use_sign] <- sign_reasons[use_sign]

  alert_signal <- compute_511_alert_zip_signal(horizon_key)
  alert_scores <- unname(alert_signal$scores[wi_zctas$zipcode])
  alert_reasons <- unname(alert_signal$reasons[wi_zctas$zipcode])
  alert_scores[!is.finite(alert_scores)] <- 0
  use_alert <- alert_scores > out_scores
  out_scores[use_alert] <- alert_scores[use_alert]
  out_reasons[use_alert] <- alert_reasons[use_alert]
  # Belt-and-suspenders: even though the upstream fetcher list now omits
  # travel-times, a stale upstream cache could still surface the legacy
  # "511WI travel delay elevated risk by N min" string here. Strip it
  # so it can't propagate into per-zip transport reason text and from
  # there into modeled road popups via build_modeled_road_risk_index.
  out_reasons <- sanitize_transport_reason(out_reasons)
  out <- list(scores = out_scores, reasons = out_reasons)
  cache_put("derived", key, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

