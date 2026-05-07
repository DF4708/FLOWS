# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/geom_utils.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: GeoJSON ring coordinates arrive in many shapes (nested lists, matrices,
# dataframes, flat numeric vectors) and downstream sf builders need a clean
# closed [n,2] matrix.
# What: returns a numeric matrix with two columns (lon, lat), guaranteed to
# close on its first vertex; returns NULL when the input cannot form a ring.
# How: coerces the input into a matrix, drops NAs, requires at least three
# points, and appends the first row to the end if it is not already closed.
# When: called by geojson_geometry_to_sfc when iterating Polygon/MultiPolygon
# coordinates from external GeoJSON payloads.
# Impact: returning NULL silently drops a ring from the resulting polygon;
# coordinate-order errors here produce inverted geometries downstream.
coords_to_matrix <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.matrix(x)) {
    mat <- x
  } else if (is.data.frame(x)) {
    mat <- as.matrix(x)
  } else {
    flat <- safe_numeric(unlist(x, recursive = TRUE, use.names = FALSE))
    flat <- flat[is.finite(flat)]
    if (length(flat) < 6) return(NULL)
    if ((length(flat) %% 2) != 0) flat <- flat[-length(flat)]
    mat <- matrix(flat, ncol = 2, byrow = TRUE)
  }
  if (ncol(mat) < 2) return(NULL)
  mat <- mat[, 1:2, drop = FALSE]
  storage.mode(mat) <- "double"
  mat <- mat[stats::complete.cases(mat), , drop = FALSE]
  if (nrow(mat) < 3) return(NULL)
  if (!isTRUE(all.equal(mat[1, ], mat[nrow(mat), ]))) mat <- rbind(mat, mat[1, , drop = FALSE])
  mat
}

# Why: many upstream alert/zone feeds return geometries as nested GeoJSON-style
# R lists rather than parsed sf objects.
# What: returns an sfc with CRS 4326 - a polygon, multipolygon, or empty
# geometrycollection if the input is malformed.
# How: dispatches on geometry$type ("Polygon"/"MultiPolygon"), runs each ring
# through coords_to_matrix, and wraps in sf::st_sfc with tryCatch fallback.
# When: called when ingesting alerts, NWS zones, and similar feeds that hand
# back raw decoded JSON geometries.
# Impact: a returned empty sfc means the feature contributes nothing to the
# map; CRS errors here would propagate as silent reprojection bugs.
geojson_geometry_to_sfc <- function(geometry) {
  empty <- sf::st_sfc(sf::st_geometrycollection(), crs = 4326)
  if (is.null(geometry) || is.null(geometry$type) || is.null(geometry$coordinates)) return(empty)
  if (identical(geometry$type, "Polygon")) {
    rings <- Filter(Negate(is.null), lapply(geometry$coordinates, coords_to_matrix))
    if (length(rings) == 0) return(empty)
    return(tryCatch(sf::st_sfc(sf::st_polygon(rings), crs = 4326), error = function(e) empty))
  }
  if (identical(geometry$type, "MultiPolygon")) {
    polys <- lapply(
      geometry$coordinates,
      function(poly) Filter(Negate(is.null), lapply(poly, coords_to_matrix))
    )
    polys <- Filter(function(poly) length(poly) > 0, polys)
    if (length(polys) == 0) return(empty)
    return(tryCatch(sf::st_sfc(sf::st_multipolygon(polys), crs = 4326), error = function(e) empty))
  }
  empty
}
