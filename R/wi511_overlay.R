# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_overlay.R - canonical empty + schema-standardising sf wrappers
# used whenever multiple 511 sub-feeds (winter / events) are rbind'd
# into a single road overlay.


# Why: the canonical empty shape is needed wherever the upstream feed is
# missing or fails so downstream rbind / merge calls don't break the
# schema.
# What: Returns the canonical empty CRS-4326 sf with all road overlay
# columns - used as fallback when 511WI feeds yield no rows.
# How: sf geometry op.
# When: called as the fallback in every fetcher / compute step when the
# upstream feed is missing or returns no rows.
# Impact: changing the column set requires a matching update in every
# fetcher / compute step that returns this empty shape on failure.
empty_road_overlay_sf <- function() {
  sf::st_sf(
    road_id = character(0),
    road_name = character(0),
    road_class = character(0),
    route_tier = character(0),
    base_speed_mph = numeric(0),
    susceptibility = numeric(0),
    driving_total_risk = numeric(0),
    road_color = character(0),
    road_opacity = numeric(0),
    road_weight = numeric(0),
    driving_risk_label = character(0),
    driving_reason_text = character(0),
    dominant_zip = character(0),
    road_source = character(0),
    official_cause_text = character(0),
    popup_label = character(0),
    geometry = sf::st_sfc(crs = 4326)
  )
}


# Why: rbind across road overlays from different sources requires a common
# column schema; we backfill any missing columns to that schema.
# What: returns x with the canonical road-overlay columns present (numeric
# defaults to 0, character defaults to "") and ordered consistently.
# How: lists required columns, fills any missing column with the right
# typed default of length nrow(x), and reorders.
# When: called before rbind in build_driving_roads_overlay (modeled +
# WI511 sources merged into one layer).
# Impact: a column added to one source but not handled here causes silent
# drop or rbind type-mismatch warnings.
standardize_road_overlay_sf <- function(x) {
  if (is.null(x) || nrow(x) == 0) return(empty_road_overlay_sf())
  needed <- c("road_id", "road_name", "road_class", "route_tier", "base_speed_mph", "susceptibility", "driving_total_risk", "road_color", "road_opacity", "road_weight", "driving_risk_label", "driving_reason_text", "dominant_zip", "road_source", "official_cause_text", "popup_label")
  for (nm in needed) {
    if (!nm %in% names(x)) {
      x[[nm]] <- if (nm %in% c("base_speed_mph", "susceptibility", "driving_total_risk", "road_opacity", "road_weight")) numeric(nrow(x)) else character(nrow(x))
    }
  }
  x[, c(needed, "geometry"), drop = FALSE]
}

