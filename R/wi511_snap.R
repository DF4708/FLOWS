# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_snap.R - snaps 511WI road overlay rows whose geometry is a
# straight-line laser between start/end points to the actual
# underlying OSM road within a buffer; preserves multi-vertex
# geometries that follow real road shapes.


# Why: WisDOT 511 publishes geometry that frequently degrades to a straight
# line ("laser") between the segment's start and end coordinates rather
# than following the actual road. Painting the laser onto the map looks
# like a diagonal line cutting across counties. We detect lasers and
# snap them to the nearest matching OSM road within a buffer.
# What: returns the input overlay sf with laser-row geometries replaced
# by the OSM road segment they were nearest to (and matched by name where
# possible).
# How: per-row, classify as laser (vertex_count <= 2 OR near-colinear
# multi-vertex with chord > 200 m and max perpendicular deviation < 75 m).
# Bulk-batch a single st_intersects of all laser buffers against the OSM
# road set, then for each laser intersect its buffer with the union of
# its candidate OSM segments. Latitude-band order yields incremental
# progress.
# When: called by build_511_roads_overlay after rbind of winter + events.
# Impact: failures pass-through (return original geometry) so a snap bug
# never drops a row from the overlay; only the visual fidelity degrades.
snap_511_overlay_to_osm_roads <- function(overlay_sf, roads_sf = NULL, buffer_m = 1500, progress = NULL) {
  if (is.null(overlay_sf) || nrow(overlay_sf) == 0) return(overlay_sf)
  if (is.null(roads_sf)) roads_sf <- tryCatch(load_wi_roads(), error = function(e) NULL)
  if (is.null(roads_sf) || nrow(roads_sf) == 0) return(overlay_sf)

  overlay_proj <- tryCatch(suppressWarnings(sf::st_transform(overlay_sf, 5070)),
                           error = function(e) NULL)
  # Use the cached projected road set; avoids a second st_transform pass.
  roads_proj <- tryCatch(load_wi_roads_proj(), error = function(e) NULL)
  if (is.null(roads_proj)) {
    roads_proj <- tryCatch(suppressWarnings(sf::st_transform(roads_sf, 5070)),
                           error = function(e) NULL)
  }
  if (is.null(overlay_proj) || is.null(roads_proj)) return(overlay_sf)

  # Restrict snap to "laser" rows (geometry doesn't follow a real road):
  #   1. vertex_count <= 2 — the API's start/end-point fallback.
  #   2. vertex_count >= 3 with chord_len > 200 m AND max perpendicular
  #      deviation from any vertex to the chord < 75 m — pseudo-laser
  #      where a few near-colinear vertices are still effectively a
  #      diagonal. Distance-based check is robust to genuinely curved
  #      roads (where deviations are typically hundreds of metres).
  geoms <- sf::st_geometry(overlay_proj)
  needs_snap <- logical(nrow(overlay_proj))
  for (i in seq_along(geoms)) {
    g <- geoms[[i]]
    if (isTRUE(sf::st_is_empty(g))) next
    coords <- tryCatch(sf::st_coordinates(g), error = function(e) NULL)
    if (is.null(coords) || nrow(coords) < 2) next
    if (nrow(coords) <= 2L) {
      needs_snap[i] <- TRUE
      next
    }
    x0 <- coords[1, "X"]; y0 <- coords[1, "Y"]
    xN <- coords[nrow(coords), "X"]; yN <- coords[nrow(coords), "Y"]
    chord_len <- sqrt((xN - x0)^2 + (yN - y0)^2)
    if (chord_len < 200) next
    vx <- coords[, "X"]; vy <- coords[, "Y"]
    cross_prod <- abs((xN - x0) * (y0 - vy) - (x0 - vx) * (yN - y0))
    max_dev <- max(cross_prod) / chord_len
    if (max_dev < 75) needs_snap[i] <- TRUE
  }
  laser_count <- sum(needs_snap)
  message(sprintf("[FLOWS-DEBUG] snap detection: %d of %d 511 rows flagged as lasers (vertex<=2 or near-colinear with chord>200m and max_dev<75m).",
                  laser_count, nrow(overlay_sf)))

  if (laser_count == 0) {
    notify_progress(progress, value = NULL,
      detail = sprintf("Snapping 511 overlays to OSM roads: 0 of %d rows need snap (skipping).",
                       nrow(overlay_sf)))
    return(overlay_sf)
  }

  laser_idx <- which(needs_snap)
  laser_bufs <- tryCatch(
    suppressWarnings(sf::st_buffer(geoms[laser_idx], buffer_m)),
    error = function(e) NULL
  )
  hits_per_laser <- if (!is.null(laser_bufs)) {
    tryCatch(suppressWarnings(sf::st_intersects(laser_bufs, roads_proj)),
             error = function(e) NULL)
  } else NULL
  if (is.null(hits_per_laser)) hits_per_laser <- vector("list", laser_count)

  laser_lat <- tryCatch({
    cents <- suppressWarnings(sf::st_centroid(geoms[laser_idx]))
    cents_4326 <- suppressWarnings(sf::st_transform(
      sf::st_sfc(cents, crs = sf::st_crs(overlay_proj)), 4326))
    suppressWarnings(sf::st_coordinates(cents_4326))[, "Y"]
  }, error = function(e) rep(NA_real_, laser_count))
  band_n <- 10L
  bins <- assign_lat_band(laser_lat, wi_bounds$south, wi_bounds$north, band_n)
  bins[!is.finite(bins)] <- 1L
  band_order <- seq.int(band_n, 1L)
  band_groups <- lapply(band_order, function(b) which(bins == b))
  total_bands <- length(band_groups)

  road_norm <- normalize_route_text(roads_sf$road_name)
  highway_token_pat <- "\\b(?:I\\s*-?\\s*\\d+|US\\s*-?\\s*\\d+|WI\\s*-?\\s*\\d+|STH\\s*-?\\s*\\d+|HWY\\s*-?\\s*\\d+|HIGHWAY\\s+\\d+)\\b"

  match_road_name <- function(seg_name_norm) {
    if (!nzchar(seg_name_norm)) return(integer(0))
    tokens <- regmatches(seg_name_norm, gregexpr(highway_token_pat, seg_name_norm, perl = TRUE))[[1]]
    if (length(tokens) == 0) return(integer(0))
    hits <- integer(0)
    for (tok in unique(tokens)) {
      tok_norm <- normalize_route_text(tok)
      if (!nzchar(tok_norm)) next
      tok_alt <- gsub("\\bSTH\\b", "WI", tok_norm)
      tok_alt2 <- gsub("\\bHIGHWAY\\b", "HWY", tok_norm)
      patt1 <- paste0("(^| )", regex_escape(tok_norm), "( |$)")
      patt2 <- paste0("(^| )", regex_escape(tok_alt), "( |$)")
      patt3 <- paste0("(^| )", regex_escape(tok_alt2), "( |$)")
      hit <- grepl(patt1, road_norm, perl = TRUE) |
             grepl(patt2, road_norm, perl = TRUE) |
             grepl(patt3, road_norm, perl = TRUE)
      hits <- unique(c(hits, which(hit)))
    }
    hits
  }

  snapped_count <- 0L
  unmatched_count <- 0L
  for (band_idx in seq_along(band_groups)) {
    band_lasers <- band_groups[[band_idx]]
    for (k in band_lasers) {
      i <- laser_idx[k]
      seg_geom <- geoms[[i]]
      if (isTRUE(sf::st_is_empty(seg_geom))) next

      candidate_idx <- hits_per_laser[[k]]
      if (length(candidate_idx) == 0) {
        unmatched_count <- unmatched_count + 1L
        next
      }

      seg_name_norm <- normalize_route_text(overlay_sf$road_name[i])
      name_idx <- match_road_name(seg_name_norm)
      if (length(name_idx) > 0) {
        named_in_buf <- intersect(candidate_idx, name_idx)
        if (length(named_in_buf) > 0) candidate_idx <- named_in_buf
      }
      if (length(candidate_idx) == 0) {
        unmatched_count <- unmatched_count + 1L
        next
      }

      seg_buf_sfc <- sf::st_sfc(laser_bufs[[k]], crs = 5070)
      cand_geom <- sf::st_geometry(roads_proj[candidate_idx, , drop = FALSE])
      snapped <- tryCatch(
        suppressWarnings(sf::st_intersection(sf::st_union(cand_geom), seg_buf_sfc)),
        error = function(e) NULL
      )
      if (is.null(snapped) || length(snapped) == 0) {
        unmatched_count <- unmatched_count + 1L
        next
      }
      if (isTRUE(sf::st_is_empty(snapped[[1]]))) {
        unmatched_count <- unmatched_count + 1L
        next
      }

      geoms[[i]] <- snapped[[1]]
      snapped_count <- snapped_count + 1L
    }
    notify_progress(progress, value = NULL,
      detail = sprintf("Snapping 511 overlays to OSM roads, band %d of %d (%d laser rows of %d total).",
                       band_idx, total_bands, laser_count, nrow(overlay_sf)))
  }
  message(sprintf("[FLOWS-DEBUG] snap result: %d/%d laser rows snapped, %d unmatched (kept original geometry).",
                  snapped_count, laser_count, unmatched_count))

  overlay_proj_snapped <- sf::st_set_geometry(overlay_proj, sf::st_sfc(geoms, crs = 5070))
  out <- tryCatch(suppressWarnings(sf::st_transform(overlay_proj_snapped, sf::st_crs(overlay_sf))),
                  error = function(e) overlay_sf)
  out
}

