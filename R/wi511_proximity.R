# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_proximity.R - per-road 511WI signal that fuses the official
# road overlay (via decayed centroid distance) with the message-sign
# road signal. Returns list(scores, reasons, sources) keyed by
# road_id.


# Why: combine the official WI511 road overlay and the message-sign road
# signal into one per-road score that reflects both sources.
# What: returns list(scores, reasons, sources) keyed by road_id.
# How: projects roads to 5070, builds within-15km neighbourhoods, decays
# nearby official scores by exp(-d/6000), then merges sign signal taking
# the max per road and recording the dominant source.
# When: called by build_driving_roads_overlay when assembling the merged
# WI511 + modeled road risk.
# Impact: the 15km radius is the dominant lever - shrinking sharpens the
# overlay; growing softens it across regions.
compute_511_road_proximity_signal <- function(horizon_key = "live", progress = NULL) {
  cache_name <- paste0("wi511-road-proximity-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  roads <- load_wi_roads()
  out_scores <- stats::setNames(rep(0, nrow(roads)), roads$road_id)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(roads)), roads$road_id)
  out_sources <- stats::setNames(rep(NA_character_, nrow(roads)), roads$road_id)
  official <- build_511_roads_overlay(horizon_key, progress = progress)
  sign_signal <- compute_511_message_sign_road_signal(horizon_key, progress = progress)
  if (nrow(roads) == 0 || (nrow(official) == 0 && !any((sign_signal$scores %||% 0) > 0))) {
    out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
    cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
    return(out)
  }
  roads_proj <- load_wi_roads_proj()
  if (is.null(roads_proj)) roads_proj <- suppressWarnings(sf::st_transform(roads, 5070))
  official_proj <- NULL
  if (nrow(official) > 0) {
    official <- repair_external_sf(official)
    official_proj <- suppressWarnings(sf::st_transform(official, 5070))
    # Within-distance via centroid pre-filter rather than line-vs-line GEOS
    # over 84k roads x 50 officials (which sample(1) showed dominates this
    # function — GEOS DistanceOp on line-line at this scale is intrinsically
    # O(N*M*verts)). Pre-compute road and official centroids in coordinate
    # space, then a vectorised AABB filter selects candidate pairs whose
    # centroid distance is under 6 km.
    hits <- tryCatch({
      road_cents <- suppressWarnings(sf::st_centroid(sf::st_geometry(roads_proj)))
      off_cents <- suppressWarnings(sf::st_centroid(sf::st_geometry(official_proj)))
      rc <- suppressWarnings(sf::st_coordinates(road_cents))
      oc <- suppressWarnings(sf::st_coordinates(off_cents))
      lapply(seq_len(nrow(rc)), function(i) {
        dx <- oc[, 1] - rc[i, 1]
        dy <- oc[, 2] - rc[i, 2]
        which((dx * dx + dy * dy) < 36000000)  # 6000^2 m^2
      })
    }, error = function(e) {
      suppressWarnings(sf::st_is_within_distance(roads_proj, official_proj, dist = 6000))
    })
  } else {
    hits <- replicate(nrow(roads), integer(0), simplify = FALSE)
  }
  band_info <- tryCatch(load_wi_roads_lat_band_groups(), error = function(e) NULL)
  band_groups <- if (!is.null(band_info)) band_info$groups else list(seq_len(nrow(roads)))
  total_bands <- length(band_groups)
  # Final shape: subset bulk distance using OFFICIAL CENTROIDS rather than
  # full linestrings. Officials post-snap follow the OSM road they're
  # attached to, so their centroid lies on or very near that road. The
  # centroid approximation discards a few hundred metres of accuracy in
  # the line-end-to-line distance, but the score formula `exp(-d/6000)`
  # is forgiving (a 200 m error at d=4 km moves the score by <2 %, well
  # below the per-band visualisation threshold).
  hit_lengths <- lengths(hits)
  hit_road_idx <- which(hit_lengths > 0)
  d_subset <- NULL
  if (length(hit_road_idx) > 0 && !is.null(official_proj) && nrow(official_proj) > 0) {
    off_centroid <- tryCatch(
      suppressWarnings(sf::st_centroid(sf::st_geometry(official_proj))),
      error = function(e) NULL
    )
    road_centroid <- tryCatch(
      suppressWarnings(sf::st_centroid(sf::st_geometry(roads_proj[hit_road_idx, , drop = FALSE]))),
      error = function(e) NULL
    )
    if (!is.null(off_centroid) && !is.null(road_centroid)) {
      road_coords <- suppressWarnings(sf::st_coordinates(road_centroid))
      off_coords <- suppressWarnings(sf::st_coordinates(off_centroid))
      d_subset <- tryCatch({
        # Outer-product approach: x_diff is (N x M), y_diff is (N x M);
        # sqrt(x_diff^2 + y_diff^2) is the distance matrix. Sub-second
        # for ~25k road centroids x ~50 official centroids vs. tens of
        # seconds via line-vs-X st_distance.
        x_diff <- outer(road_coords[, 1], off_coords[, 1], "-")
        y_diff <- outer(road_coords[, 2], off_coords[, 2], "-")
        m <- sqrt(x_diff * x_diff + y_diff * y_diff)
        m[!is.finite(m)] <- 6000
        m
      }, error = function(e) NULL)
    }
  }
  hit_idx_pos <- stats::setNames(seq_along(hit_road_idx), as.character(hit_road_idx))
  off_risk <- if (!is.null(official_proj)) safe_numeric(official$driving_total_risk %||% 0) else numeric(0)
  off_reason <- if (!is.null(official_proj)) as.character(official$driving_reason_text %||% rep("", nrow(official))) else character(0)
  off_source <- if (!is.null(official_proj)) as.character(official$road_source %||% rep("", nrow(official))) else character(0)
  for (band_idx in seq_along(band_groups)) {
    band_rows <- band_groups[[band_idx]]
    for (i in band_rows) {
      idx <- unique(as.integer(hits[[i]]))
      if (length(idx) == 0) next
      pos <- hit_idx_pos[[as.character(i)]]
      d <- if (!is.null(d_subset) && !is.null(pos)) d_subset[pos, idx] else {
        v <- safe_numeric(sf::st_distance(roads_proj[i, ], official_proj[idx, ]))
        v[!is.finite(v)] <- 6000
        v
      }
      vals <- off_risk[idx]
      if (!any(vals > 0)) next
      local_scores <- pmin(1, vals * exp(-pmax(d, 0) / 6000))
      if (!any(is.finite(local_scores) & local_scores > 0)) next
      best <- which.max(local_scores)[1]
      out_scores[i] <- local_scores[best]
      out_reasons[i] <- paste0(off_reason[idx[best]], " Nearby official corridor conditions are influencing this road.")
      out_sources[i] <- if (nzchar(off_source[idx[best]])) off_source[idx[best]] else "511WI"
    }
    notify_progress(progress, value = NULL,
      detail = sprintf("Computing 511 road proximity, band %d of %d.",
                       band_idx, total_bands))
  }
  sign_scores <- sign_signal$scores %||% out_scores
  sign_reasons <- sign_signal$reasons %||% out_reasons
  sign_sources <- sign_signal$sources %||% out_sources
  if (length(sign_scores) > 0) {
    common_ids <- intersect(names(out_scores), names(sign_scores))
    better <- common_ids[sign_scores[common_ids] > out_scores[common_ids]]
    if (length(better) > 0) {
      out_scores[better] <- sign_scores[better]
      out_reasons[better] <- as.character(sign_reasons[better])
      out_sources[better] <- as.character(sign_sources[better])
    }
  }
  out <- list(scores = out_scores, reasons = out_reasons, sources = out_sources)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

