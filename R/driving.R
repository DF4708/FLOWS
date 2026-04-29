# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/driving.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: synthesise a single per-ZIP "driving risk" score by combining 11
# weather/hazard component scores with weights tuned to road impact.
# What: returns the input zips data.frame with three new columns:
# driving_total_risk (0..1), driving_reason_text, and driving_risk_label.
# How: builds 11 normalised vectors (flood, winter, convective, wind/vis, ...),
# applies probabilistic OR (1 - prod(1 - x_i)) for the total, picks the
# dominant component for the reason text, and overrides reason text from
# upstream layer-specific reason fields when applicable.
# When: called by the layer builder right after all per-hazard scores have
# been populated for the ZIP frame.
# Impact: the per-component coefficients here decide what tilts the driving
# layer into red - a flood weight bump elevates driving risk during storms.
compute_driving_risk <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) {
    zips$driving_total_risk <- numeric(0)
    zips$driving_reason_text <- character(0)
    zips$driving_risk_label <- character(0)
    return(zips)
  }

  n <- nrow(zips)
  normalize_drive_col <- function(x) {
    x <- safe_numeric(x)
    if (length(x) == 0) x <- rep(0, n)
    if (length(x) != n) x <- rep_len(x, n)
    x[!is.finite(x)] <- 0
    pmin(1, pmax(0, x))
  }

  convective_blend <- pmin(1, pmax(zips$convective_total_score %||% 0, 0.65 * (zips$wind_total_score %||% 0) + 0.35 * (zips$pop_risk_score %||% 0), na.rm = TRUE))
  visibility_signal <- rep(0, nrow(zips))
  if (!is.null(zips$alert_event)) {
    visibility_signal <- ifelse(grepl("fog|smoke|dust", tolower(zips$alert_event %||% "")), pmax(zips$alert_score %||% 0, 0.45), 0)
  }

  drive_flood <- pmin(1, 1.00 * (zips$flood_total_score %||% 0))
  drive_winter <- pmin(1, 1.00 * (zips$winter_total_score %||% 0))
  drive_convective <- pmin(1, 0.90 * convective_blend)
  drive_precipitation <- pmin(1, pmax(0.70 * (zips$pop_risk_score %||% 0), 0.85 * (zips$qpf_risk_score %||% 0), na.rm = TRUE))
  drive_windvis <- pmin(1, pmax(1.00 * (zips$wind_total_score %||% 0), visibility_signal, na.rm = TRUE))
  drive_fire <- pmin(1, 0.90 * pmax(zips$fire_total_score %||% 0, zips$air_total_score %||% 0, na.rm = TRUE))
  drive_heat <- pmin(1, 0.55 * (zips$heat_total_score %||% 0))
  drive_cold <- pmin(1, 0.60 * pmax(zips$cold_total_score %||% 0, 0.60 * (zips$winter_total_score %||% 0), na.rm = TRUE))
  drive_radiation <- pmin(1, 0.40 * (zips$radiation_total_score %||% 0))
  drive_seismic <- pmin(1, 0.95 * (zips$seismic_total_score %||% 0))
  drive_transport <- pmin(1, pmax(0.60 * visibility_signal, 0.35 * (zips$air_total_score %||% 0), zips$wi511_transport_score %||% 0, na.rm = TRUE))

  mat <- as.matrix(data.frame(
    flood = normalize_drive_col(drive_flood),
    winter = normalize_drive_col(drive_winter),
    convective = normalize_drive_col(drive_convective),
    precipitation = normalize_drive_col(drive_precipitation),
    wind_visibility = normalize_drive_col(drive_windvis),
    fire_smoke = normalize_drive_col(drive_fire),
    heat = normalize_drive_col(drive_heat),
    cold = normalize_drive_col(drive_cold),
    radiation = normalize_drive_col(drive_radiation),
    seismic = normalize_drive_col(drive_seismic),
    transport = normalize_drive_col(drive_transport),
    check.names = FALSE
  ))
  mat[!is.finite(mat)] <- 0
  zips$driving_total_risk <- 1 - Reduce(`*`, as.data.frame(1 - mat))
  dominant_idx <- max.col(mat, ties.method = "first")
  dominant_names <- colnames(mat)[dominant_idx]
  reason_map <- c(
    flood = "Driving hazard elevated by flood guidance, precipitation, or river conditions.",
    winter = "Driving hazard elevated by snow, ice, or winter impacts.",
    convective = "Driving hazard elevated by thunderstorm, hail, lightning, or convective conditions.",
    precipitation = "Driving hazard elevated by wet-road or heavy-rainfall conditions.",
    wind_visibility = "Driving hazard elevated by wind, visibility, or roadway exposure.",
    fire_smoke = "Driving hazard elevated by fire-weather guidance or smoke conditions.",
    heat = "Driving hazard elevated by high heat and vehicle or roadway stress.",
    cold = "Driving hazard elevated by cold exposure or freezing conditions.",
    radiation = if (!is.null(zips$radiation_reason_text) && nzchar(trimws(as.character(zips$radiation_reason_text %||% ""))[1])) "Driving hazard elevated by radiological or UV conditions." else "Driving hazard elevated by radiation exposure or UV conditions.",
    seismic = "Driving hazard elevated by recent seismic activity.",
    transport = "Driving hazard elevated by transportation visibility issues."
  )
  zips$driving_reason_text <- unname(reason_map[dominant_names])
  # When the dominant hazard has a non-empty per-ZIP reason text, prefer that
  # over the generic reason_map fallback. Iterating a (dominant_name, source
  # column) table avoids four near-identical mask-and-assign blocks.
  reason_overrides <- list(
    flood       = zips$flood_reason_text,
    convective  = zips$convective_reason_text,
    radiation   = zips$radiation_reason_text,
    transport   = zips$wi511_transport_reason
  )
  for (key in names(reason_overrides)) {
    src <- reason_overrides[[key]]
    if (is.null(src)) next
    mask <- dominant_names == key & is_nontrivial_string(src)
    if (any(mask)) zips$driving_reason_text[mask] <- as.character(src[mask])
  }
  zips$driving_reason_text[!is.finite(zips$driving_total_risk) | zips$driving_total_risk <= 0] <- "All clear."
  zips$driving_risk_label <- vapply(zips$driving_total_risk, risk_label_from_score, character(1))
  zips
}

# Why: paint road segments with risk colour - the driving layer's most
# expensive output - and merge in any official WI511 incident overlay.
# What: returns an sf of roads with road_color, road_opacity, road_weight,
# popup_label, etc., or empty_road_overlay_sf() when nothing is at risk.
# How: signature-keys the cache by ZIP risk + WI511 reason; on miss, joins
# wi_roads to relevant ZIPs (>= 0.02 score), assigns road risk via
# build_modeled_road_risk_index, draws popups, then row-binds the WI511
# official overlay before saving snapshot and releasing memory.
# When: called by the server-side road-overlay reactive whenever the ZIP
# risk frame or horizon changes.
# Impact: this is the dominant cost of the driving view - cache invalidation
# and snapshot TTL must stay correctly tuned per horizon (live vs forecast).
build_driving_roads_overlay <- function(zips, horizon_key = "live") {
  if (is.null(zips) || nrow(zips) == 0) return(empty_road_overlay_sf())
  road_sig <- paste(
    zips$zipcode,
    sprintf("%.4f", safe_numeric(zips$driving_total_risk %||% 0)),
    ifelse(is.na(zips$driving_reason_text %||% NA_character_), "", as.character(zips$driving_reason_text %||% "")),
    ifelse(is.na(zips$wi511_transport_reason %||% NA_character_), "", as.character(zips$wi511_transport_reason %||% "")),
    sep = "|"
  )
  cache_name <- paste0("roads-overlay-", horizon_key, "-", cache_hash_string(paste(road_sig, collapse = "||")))
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  ttl <- if (identical(horizon_key, "live")) max(12L, ALERT_TTL_SECONDS) else if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
  snap_path <- runtime_snapshot_file(sprintf("derived_%s", cache_name))
  persisted <- load_runtime_snapshot(snap_path, max_age_seconds = if (identical(horizon_key, "live")) max(120L, ttl) else ttl)
  if (!is.null(persisted)) {
    cache_put("derived", cache_name, persisted, ttl_seconds = if (identical(horizon_key, "live")) max(120L, ttl) else ttl)
    return(persisted)
  }

  modeled <- empty_road_overlay_sf()
  roads <- load_wi_roads()
  lookup <- load_road_zip_lookup()
  relevant_zipcodes <- get_relevant_road_zipcodes(zips, min_score = 0.02)
  if (length(relevant_zipcodes) > 0) {
    keep_ids <- names(lookup)[vapply(
      lookup,
      function(z) {
        any(z %in% relevant_zipcodes)
      },
      logical(1)
    )]
    roads <- roads[roads$road_id %in% keep_ids, , drop = FALSE]
  } else {
    roads <- roads[0, , drop = FALSE]
  }

  if (nrow(roads) > 0) {
    road_risk <- build_modeled_road_risk_index(roads, lookup, zips)
    match_idx <- match(roads$road_id, road_risk$road_id)
    roads$driving_total_risk <- unname(road_risk$driving_total_risk[match_idx])
    roads$driving_total_risk[!is.finite(roads$driving_total_risk)] <- 0
    keep <- is.finite(roads$driving_total_risk) & roads$driving_total_risk > 0
    roads <- roads[keep, , drop = FALSE]

    if (nrow(roads) > 0) {
      road_risk <- road_risk[match(roads$road_id, road_risk$road_id), , drop = FALSE]
      roads$road_color <- risk_rgb_hex(roads$driving_total_risk)
      roads$road_opacity <- ifelse((roads$driving_total_risk %||% 0) >= RISK_GREEN_MIN, 0.50, 0)
      roads$road_weight <- ifelse(roads$road_class == "Primary", 4.2, 3.0)
      roads$driving_risk_label <- vapply(roads$driving_total_risk, risk_label_from_score, character(1))
      roads$driving_reason_text <- as.character(road_risk$driving_reason_text %||% rep("All clear.", nrow(roads)))
      roads$dominant_zip <- as.character(road_risk$dominant_zip %||% rep(NA_character_, nrow(roads)))
      roads$road_source <- as.character(road_risk$road_source %||% rep("Modeled ZIP risk", nrow(roads)))
      roads$official_cause_text <- as.character(road_risk$official_cause_text %||% rep("none", nrow(roads)))
      roads$popup_label <- sprintf(
        paste0(
          '<div style="min-width:250px;">',
          '<div style="font-weight:700; margin-bottom:0.35rem;">%s</div>',
          '<div><strong>Source:</strong> %s</div>',
          '<div><strong>Road class:</strong> %s</div>',
          '<div><strong>Driving risk:</strong> %s</div>',
          '<div><strong>Official cause:</strong> %s</div>',
          '<div><strong>Reason:</strong> %s</div>',
          '<div><strong>Dominant ZIP:</strong> %s</div>',
          '</div>'
        ),
        escape_html(roads$road_name),
        escape_html(roads$road_source),
        escape_html(roads$road_class),
        escape_html(roads$driving_risk_label),
        escape_html(roads$official_cause_text),
        escape_html(roads$driving_reason_text),
        escape_html(roads$dominant_zip)
      )
      modeled <- standardize_road_overlay_sf(roads)
    }
  }

  official <- build_511_roads_overlay(horizon_key)
  out <- tryCatch(
    suppressWarnings(rbind(standardize_road_overlay_sf(modeled), standardize_road_overlay_sf(official))),
    error = function(e) standardize_road_overlay_sf(modeled)
  )
  if (!is.null(out) && nrow(out) > 0) {
    out$road_color <- risk_rgb_hex(out$driving_total_risk)
    out$road_opacity <- ifelse((out$driving_total_risk %||% 0) >= RISK_GREEN_MIN, 0.50, 0)
  }
  invalidate_replaced_live_payloads("derived", prefix = paste0("roads-overlay-", horizon_key), keep_key = cache_name)
  cache_put("derived", cache_name, out, ttl_seconds = if (identical(horizon_key, "live")) max(120L, ttl) else ttl)
  save_runtime_snapshot(snap_path, out)
  release_runtime_memory()
  out
}
