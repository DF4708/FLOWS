# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/heatrisk.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: the NWS HeatRisk forecast is a daily KML overlay; we cache the parsed sf
# object so the live map does not re-download on every reactive tick.
# What: returns an sf data frame in CRS 4326 (or an empty fallback sf with
# zipcode/geometry columns if the fetch fails).
# How: looks up the URL in HEATRISK_KML_URLS by horizon, calls
# read_latest_sf with a 3-hour TTL via the "reference" cache namespace.
# When: called by the layer builder whenever the heat layer is enabled or the
# horizon selector changes.
# Impact: a bad URL or parse error degrades to an empty geometry, hiding the
# layer; cache mis-keying would cause cross-horizon contamination.
get_heatrisk_sf <- function(horizon_key = "live") {
  key <- paste0("heatrisk-", horizon_key)
  cached <- cache_get("reference", key)
  if (!is.null(cached)) return(cached)
  url <- HEATRISK_KML_URLS[[horizon_key]] %||% HEATRISK_KML_URLS[["live"]]
  obj <- tryCatch(read_latest_sf("reference", key, url, ttl_seconds = 3 * 3600), error = function(e) wi_zctas[0, c("zipcode", "geometry")])
  ensure_crs_4326(obj)
}

# Why: HeatRisk encodes severity as both numeric class (0-4) and labels
# ("magenta", "extreme"), but the rest of our scoring pipeline needs a single
# normalised 0..1 risk number.
# What: returns a numeric in [0,1] mapped to the green/yellow/red threshold
# constants; 0 if the input is empty/non-finite.
# How: text path matches keywords to a band, numeric path clamps to 0..4 and
# indexes into a fixed score table aligned with RISK_*_MIN constants.
# When: invoked per feature by heatrisk_value_from_row when computing a ZIP-
# level heat-risk score during overlay generation.
# Impact: any change shifts the relative weight of heat vs other hazards in
# the composite map score, since the bands match shared global thresholds.
score_heatrisk_value <- function(val) {
  if (is.character(val) || is.factor(val)) {
    txt <- tolower(paste(val, collapse = " "))
    if (grepl("extreme|magenta", txt)) return(1.00)
    if (grepl("major|(^|[^a-z])red([^a-z]|$)", txt, perl = TRUE)) return(RISK_RED_MIN)
    if (grepl("moderate|orange", txt)) return(RISK_YELLOW_MIN)
    if (grepl("minor|yellow", txt)) return(RISK_GREEN_MIN)
    if (grepl("little to none|little to no|green", txt)) return(0.00)
  }
  num <- safe_numeric(val[1])
  if (!is.finite(num)) return(0)
  num <- pmax(0, pmin(4, num))
  c(0.00, RISK_GREEN_MIN, RISK_YELLOW_MIN, RISK_RED_MIN, 1.00)[num + 1]
}

# Why: KML attributes vary across HeatRisk publications - sometimes the class
# is in "gridcode", sometimes "pixel" or a verbose "class" label.
# What: returns a 0..1 risk score for the row by probing both numeric and text
# attribute candidates.
# How: first tries extract_named_numeric on a list of likely numeric columns;
# if that fails, concatenates the row to text and runs score_heatrisk_value.
# When: called by the heatrisk overlay builder for each polygon to build a
# per-feature score before the spatial join with ZCTAs.
# Impact: a missing attribute name in the candidate list silently downgrades
# every feature to the text path, which is more brittle.
heatrisk_value_from_row <- function(row) {
  num <- extract_named_numeric(row, c("heatrisk", "gridcode", "pixel", "value", "class", "risk"))
  if (is.finite(num) && num >= 0 && num <= 4) return(score_heatrisk_value(num))
  txt <- paste(unlist(row, use.names = FALSE), collapse = " | ")
  score_heatrisk_value(txt)
}
