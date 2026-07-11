# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# export_app_risk_bundle.R — compact JSON export of the R engine's ZIP-level
# risk field for the native app (apple/, RiskFieldService.swift).
#
# The web app's decision surface — normalized environmental score, per-family
# scores (the Map Filter's 11 primary maps), and the per-ZIP hazard summary
# text — comes out of the full R scoring pipeline. Rather than re-implement
# that on-device, this exports the already-computed field from the warmed
# startup snapshot so the app renders the SAME numbers the web map shows.
#
# Output: data/runtime_cache/app_risk_bundle.json
#   { generated_utc, horizon, families: [...],
#     zips: [ { z, c:[lon,lat], s:[per-family 0..1], t:"hazard summary" ,
#               p:[[lon,lat],...simplified outer ring] } ] }
#
# Run: Rscript scripts/export_app_risk_bundle.R
# (Re-run whenever the snapshot is rewarmed; scripts/sync_to_shared.sh copies
# runtime_cache/app_risk_bundle.json alongside the snapshot.)

suppressWarnings(suppressMessages({
  source("global.R", chdir = TRUE)
  library(jsonlite)
}))

snap <- load_runtime_snapshot(STARTUP_MAP_SNAPSHOT_PATH, max_age_seconds = Inf)
payload <- snap$payload %||% snap
polys <- payload$polys
stopifnot(!is.null(polys), nrow(polys) > 0)

# Same family -> column mapping as compute_primary_fill_score (R/families.R).
family_cols <- c(
  environmental = "normalized_risk_score",
  wind          = "wind_total_score",
  qpf_flood     = "flood_total_score",
  winter        = "winter_total_score",
  fire          = "fire_total_score",
  convective    = "convective_total_score",
  heat          = "heat_total_score",
  cold          = "cold_total_score",
  air           = "air_total_score",
  radiation     = "radiation_total_score",
  seismic       = "seismic_total_score"
)
present <- family_cols[family_cols %in% names(polys)]
if (length(present) < length(family_cols)) {
  cat("note: missing family columns:",
      paste(setdiff(names(family_cols), names(present)), collapse = ", "), "\n")
}

zip_col <- intersect(c("zipcode", "zip", "ZCTA5CE20", "GEOID20", "GEOID"), names(polys))[1]
stopifnot(!is.na(zip_col))

score_matrix <- vapply(present, function(col) {
  v <- safe_numeric(polys[[col]])
  v[!is.finite(v)] <- 0
  round(pmin(1, pmax(0, v)), 3)
}, numeric(nrow(polys)))

summaries <- as.character(polys$risk_type_summary_text %||% rep("", nrow(polys)))
summaries[is.na(summaries)] <- ""
summaries <- substr(trimws(summaries), 1, 140)

cat("simplifying", nrow(polys), "ZIP polygons...\n")
geom <- sf::st_geometry(polys)
simplified <- sf::st_simplify(geom, dTolerance = 0.008, preserveTopology = TRUE)
centroids <- suppressWarnings(sf::st_coordinates(sf::st_point_on_surface(geom)))

ring_of <- function(g) {
  # Largest outer ring, rounded to 4 dp (~11 m) for size.
  polys_m <- suppressWarnings(sf::st_cast(sf::st_sfc(g), "POLYGON"))
  if (length(polys_m) == 0) return(NULL)
  areas <- vapply(polys_m, function(p) as.numeric(sf::st_area(p)), numeric(1))
  ring <- sf::st_coordinates(polys_m[[which.max(areas)]])
  # Review finding: taking every row concatenated hole rings (lakes) onto the
  # exterior ring, producing self-intersecting app polygons. Keep only the
  # exterior (L1 == 1).
  if ("L1" %in% colnames(ring)) ring <- ring[ring[, "L1"] == 1, , drop = FALSE]
  if (nrow(ring) < 4) return(NULL)
  round(unname(ring[, 1:2, drop = FALSE]), 4)
}

zips_out <- lapply(seq_len(nrow(polys)), function(i) {
  ring <- tryCatch(ring_of(simplified[[i]]), error = function(e) NULL)
  entry <- list(
    z = as.character(polys[[zip_col]][i]),
    c = round(c(centroids[i, 1], centroids[i, 2]), 4),
    s = unname(score_matrix[i, ])
  )
  if (nzchar(summaries[i])) entry$t <- summaries[i]
  if (!is.null(ring)) entry$p <- ring
  entry
})

bundle <- list(
  generated_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  horizon = "live",
  families = names(present),
  zips = zips_out
)

out_path <- file.path("data", "runtime_cache", "app_risk_bundle.json")
write_json(bundle, out_path, auto_unbox = TRUE, digits = 4)
cat(sprintf("wrote %s: %d zips, %d families, %.1f MB\n",
            out_path, length(zips_out), length(present),
            file.size(out_path) / 1e6))

# Also stage a copy into the app's Resources so sandboxed installed builds
# (which cannot read ~/Documents or /Users/Shared) load the field from
# Bundle.main. Rebuild the app after re-exporting to pick it up.
app_copy <- file.path("apple", "FLOWS", "Resources", "app_risk_bundle.json")
if (dir.exists(dirname(app_copy))) {
  file.copy(out_path, app_copy, overwrite = TRUE)
  cat(sprintf("staged %s for the app bundle\n", app_copy))
}
