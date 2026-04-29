# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/polyline.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: routing providers (Google/HERE/etc.) return polylines as the compact
# Google encoded-polyline string, but our map layer needs lon/lat coordinates.
# What: returns a numeric [n,2] matrix with columns "lon"/"lat" (empty matrix
# if encoded is empty or malformed).
# How: implements the standard varint-with-zigzag decoder, accumulating signed
# lat/lon deltas scaled by 1e-5.
# When: called for each route or alert geometry that arrives as an encoded
# polyline before being wrapped into an sf linestring.
# Impact: a bug in shift/accumulator math would offset every coordinate; the
# returned matrix is the geometric ground truth for the rest of the pipeline.
decode_polyline_matrix <- function(encoded) {
  encoded <- safe_string(encoded)
  if (!nzchar(encoded)) return(matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat"))))
  index <- 1L
  lat <- 0L
  lon <- 0L
  len <- nchar(encoded)
  coords <- vector("list", 0)

  decode_value <- function() {
    result <- 0L
    shift <- 0L
    repeat {
      if (index > len) return(NULL)
      b <- utf8ToInt(substr(encoded, index, index)) - 63L
      index <<- index + 1L
      result <- bitwOr(result, bitwShiftL(bitwAnd(b, 0x1fL), shift))
      shift <- shift + 5L
      if (b < 0x20L) break
    }
    if (bitwAnd(result, 1L) != 0L) {
      -bitwShiftR(result, 1L) - 1L
    } else {
      bitwShiftR(result, 1L)
    }
  }

  repeat {
    dlat <- decode_value()
    if (is.null(dlat)) break
    dlon <- decode_value()
    if (is.null(dlon)) break
    lat <- lat + dlat
    lon <- lon + dlon
    coords[[length(coords) + 1L]] <- c(lon / 1e5, lat / 1e5)
  }

  if (length(coords) == 0) return(matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat"))))
  out <- do.call(rbind, coords)
  colnames(out) <- c("lon", "lat")
  out
}

# Wraps a [n,2] lon/lat matrix into a CRS-4326 sf linestring sfc, returning an empty geometrycollection if too few points.
linestring_sfc_from_matrix <- function(mat) {
  if (is.null(mat) || length(mat) == 0 || nrow(mat) < 2) {
    return(sf::st_sfc(sf::st_geometrycollection(), crs = 4326))
  }
  sf::st_sfc(sf::st_linestring(as.matrix(mat[, c("lon", "lat"), drop = FALSE])), crs = 4326)
}

# Why: some providers return only an ordered list of waypoints (no encoded
# polyline), so we synthesise a coarse linestring from their coordinates.
# What: returns a CRS-4326 sf linestring sfc threading start, each waypoint,
# and end; an empty geometrycollection if fewer than 2 finite points exist.
# How: pushes finite (lon,lat) pairs into a list (using
# extract_named_numeric_any to handle assorted key spellings) and rbinds.
# When: fallback path in driving/routing builders when the provider response
# lacks a polyline but does include via points.
# Impact: producing an empty geometry suppresses the route line on the map;
# losing a waypoint here yields a noticeably wrong "shortcut" segment.
linestring_sfc_from_waypoints <- function(waypoints, start_lon = NA_real_, start_lat = NA_real_, end_lon = NA_real_, end_lat = NA_real_) {
  pts <- list()
  add_point <- function(lon, lat) {
    if (is.finite(lon) && is.finite(lat)) pts[[length(pts) + 1L]] <<- c(lon, lat)
  }
  add_point(start_lon, start_lat)
  if (is.list(waypoints) && length(waypoints) > 0) {
    for (wp in waypoints) {
      lon <- extract_named_numeric_any(wp, c("Longitude", "longitude", "Lon", "lng", "x"))
      lat <- extract_named_numeric_any(wp, c("Latitude", "latitude", "Lat", "lat", "y"))
      add_point(lon, lat)
    }
  }
  add_point(end_lon, end_lat)
  if (length(pts) < 2) return(sf::st_sfc(sf::st_geometrycollection(), crs = 4326))
  mat <- do.call(rbind, pts)
  colnames(mat) <- c("lon", "lat")
  if (nrow(mat) >= 2) mat <- unique(mat)
  linestring_sfc_from_matrix(mat)
}
