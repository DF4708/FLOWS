# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/families.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Returns the canonical hazard family name for a given alert event text by checking each family in priority order.
categorize_alert_type <- function(event) {
  families <- c("flood", "cold", "winter", "convective", "fire", "heat", "air", "radiation", "seismic", "wind")
  match_idx <- families[vapply(families, function(fm) alert_matches_family(event, fm), logical(1))]
  if (length(match_idx) > 0) return(match_idx[1])
  "general"
}

# Why: every alert needs to be tagged with a hazard family so the right
# family score gets the alert support boost.
# What: returns TRUE if event text matches the keyword regex for the named
# family, FALSE otherwise (also FALSE for unknown families).
# How: lowercases event and switches on family, running grepl against
# family-specific keyword bundles (e.g., flood matches "flood|hydrologic|surf").
# When: called by categorize_alert_type and elsewhere when joining alert
# events into per-family score columns.
# Impact: extending an alert vocabulary (e.g., a new "lake wind advisory")
# requires editing the matching family regex here.
alert_matches_family <- function(event, family) {
  ev <- tolower(safe_string(event))
  family <- tolower(safe_string(family))
  switch(
    family,
    flood = grepl("flood|hydrologic|surf|rip current", ev),
    cold = grepl("wind chill|extreme cold|cold weather|hard freeze|freeze warning|frost", ev),
    winter = grepl("winter|snow|blizzard|freezing rain|ice storm|ice|sleet", ev),
    convective = grepl("tornado|thunderstorm|hail|convective|severe weather|lightning", ev),
    fire = grepl("red flag|fire weather", ev),
    heat = grepl("heat|uv", ev),
    air = grepl("air quality|smoke|dust", ev),
    radiation = grepl("radiological|nuclear", ev),
    seismic = grepl("earthquake|seismic", ev),
    wind = grepl("tornado|severe thunderstorm|damaging wind|high wind|wind advisory|wind|gale|small craft|marine|beach hazards|lake wind|brisk|fog", ev),
    FALSE
  )
}

# Returns a named numeric vector (Wind/Flood/Winter/Storm/Fire/Heat/Cold/Air/Radiation/Seismic) extracted from a zip row's *_total_score columns.
risk_family_scores <- function(row) {
  c(
    "Wind" = row[["wind_total_score"]] %||% row[["wind_risk_score"]] %||% 0,
    "Flood" = row[["flood_total_score"]] %||% 0,
    "Winter" = row[["winter_total_score"]] %||% 0,
    "Storm" = row[["convective_total_score"]] %||% 0,
    "Fire" = row[["fire_total_score"]] %||% 0,
    "Heat" = row[["heat_total_score"]] %||% 0,
    "Cold" = row[["cold_total_score"]] %||% 0,
    "Air" = row[["air_total_score"]] %||% 0,
    "Radiation" = row[["radiation_total_score"]] %||% 0,
    "Seismic" = row[["seismic_total_score"]] %||% 0
  )
}

# Returns the name of the highest-scoring risk family for a row, or NA_character_ when every family scores zero.
dominant_risk_family <- function(row) {
  families <- risk_family_scores(row)
  families[!is.finite(families)] <- 0
  if (!length(families) || max(families, na.rm = TRUE) <= 0) return(NA_character_)
  names(which.max(families))[1]
}

# Why: the popup needs a per-family breakdown that explains why a given
# family's total ended up where it did.
# What: returns a named numeric vector of component contributions for the
# requested family, or "No material contributors" => 0 when family is NA.
# How: branches on family_name and pulls the appropriate per-component
# scores from row, applying the same family-specific blending coefficients
# used when totals were originally computed.
# When: called by compose_risk_type_summary while rendering popup text.
# Impact: any drift between coefficients here and those in the upstream
# scorers will mislead users about which input drove the score.
risk_type_components_for_family <- function(row, family_name = NA_character_) {
  cold_factor <- ifelse(is.finite(row[["forecast_temperature_f"]] %||% NA_real_) && (row[["forecast_temperature_f"]] %||% NA_real_) <= 34, 1, 0)
  switch(
    family_name %||% "",
    "Flood" = c(
      "Alert support" = row[["flood_alert_component"]] %||% 0,
      "Rain/QPF" = row[["flood_qpf_component"]] %||% 0,
      "River gauge" = row[["flood_river_component"]] %||% 0,
      "River corridor/NWM" = row[["flood_corridor_component"]] %||% 0,
      "Off-gauge hydrology" = row[["flood_offgauge_component"]] %||% 0,
      "WPC flood outlook" = row[["flood_outlook_component"]] %||% 0,
      "Flash-flood guidance" = row[["flood_ffg_component"]] %||% 0,
      "NOAA flood hazard outlook" = row[["flood_fho_component"]] %||% 0
    ),
    "Winter" = c(
      "Alert support" = soft_alert_signal(row[["winter_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.72),
      "Snow/ice guidance" = 0.55 * (row[["winter_risk_score"]] %||% 0),
      "Wind support" = 0.20 * (row[["wind_risk_score"]] %||% 0),
      "Freezing precip support" = 0.25 * ((row[["qpf_risk_score"]] %||% 0) * cold_factor)
    ),
    "Storm" = c(
      "Alert support" = soft_alert_signal(row[["convective_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.78),
      "SPC guidance" = row[["convective_guidance_score"]] %||% 0,
      "GLM lightning" = row[["glm_lightning_total_score"]] %||% 0,
      "Wind support" = 0.60 * (row[["wind_total_score"]] %||% 0),
      "Rain support" = 0.40 * (row[["pop_risk_score"]] %||% 0)
    ),
    "Fire" = c(
      "Alert support" = soft_alert_signal(row[["fire_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.60),
      "Fire guidance" = row[["fire_risk_score"]] %||% 0,
      "Smoke support" = 0.55 * (row[["air_total_score"]] %||% 0)
    ),
    "Heat" = c(
      "Alert support" = soft_alert_signal(row[["heat_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.58),
      "Heat guidance" = 0.75 * pmax(row[["heatrisk_official_score"]] %||% 0, row[["heat_risk_score"]] %||% 0, na.rm = TRUE),
      "UV support" = 0.25 * (row[["uv_total_score"]] %||% 0)
    ),
    "Cold" = c(
      "Alert support" = soft_alert_signal(row[["cold_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.62),
      "Cold exposure" = 0.70 * (row[["cold_risk_score"]] %||% 0),
      "Winter support" = 0.30 * (row[["winter_total_score"]] %||% 0)
    ),
    "Air" = c(
      "Alert support" = soft_alert_signal(row[["air_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.58),
      "AirNow" = row[["airnow_total_score"]] %||% 0,
      "Smoke / fire support" = 0.55 * (row[["fire_risk_score"]] %||% 0)
    ),
    "Radiation" = c(
      "Alert support" = soft_alert_signal(row[["radiation_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.92),
      "RadNet" = row[["radnet_total_score"]] %||% 0,
      "NRC events" = row[["nrc_total_score"]] %||% 0,
      "UV" = row[["uv_total_score"]] %||% 0
    ),
    "Seismic" = c(
      "Alert support" = soft_alert_signal(row[["seismic_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.92),
      "USGS seismic" = row[["seismic_live_score"]] %||% row[["seismic_total_score"]] %||% 0
    ),
    "Wind" = c(
      "Alert support" = soft_alert_signal(row[["wind_alert_score"]] %||% 0, event = row[["alert_event"]] %||% "", weight = 0.72),
      "Forecast wind" = row[["wind_risk_score"]] %||% 0
    ),
    c("No material contributors" = 0)
  )
}

# Returns a top-5 "family score%" bullet string (e.g., "Flood 42% • Wind 18% ...") for popup display, or a placeholder when nothing scored.
compose_risk_component_summary <- function(row) {
  families <- risk_family_scores(row)
  families[!is.finite(families)] <- 0
  families <- sort(families[families > 0], decreasing = TRUE)
  if (length(families) == 0) return("No material contributors.")
  families <- utils::head(families, 5L)
  paste(sprintf("%s %s", names(families), format_score_pct(families)), collapse = " • ")
}

# Returns the popup type-summary line ("<DominantFamily>: <component breakdown>") restricted to the top 5 components.
compose_risk_type_summary <- function(row) {
  family_name <- dominant_risk_family(row)
  if (!nzchar(family_name %||% "")) return("No material contributors.")
  components <- risk_type_components_for_family(row, family_name)
  components[!is.finite(components)] <- 0
  components <- sort(components[components > 0], decreasing = TRUE)
  family_scores <- risk_family_scores(row)
  family_score <- safe_numeric(family_scores[family_name])
  if (!length(family_score) || !is.finite(family_score)) family_score <- 0
  if (length(components) == 0) return(sprintf("%s %s", family_name, format_score_pct(family_score)))
  components <- utils::head(components, 5L)
  sprintf("%s: %s", family_name, paste(sprintf("%s %s", names(components), format_score_pct(components)), collapse = " • "))
}

# Why: each ZIP needs a one-sentence "why is this red" explanation that is
# specific to its dominant hazard family.
# What: returns a sentence describing the dominant hazard, preferring an
# active alert event when present, else a family-specific reason text.
# How: if alert_event is present, returns it; otherwise picks the highest
# *_total_score family and returns either that family's pre-built reason
# text column or a hand-written default.
# When: called per ZIP when assembling the popup risk_reason_text column.
# Impact: this is the user-facing rationale; bad fallbacks here turn into
# confusing or generic popups.
compose_risk_reason <- function(row) {
  if (!is.na(row[["alert_event"]]) && nzchar(as.character(row[["alert_event"]]))) return(as.character(row[["alert_event"]]))
  candidates <- c(
    flood = row[["flood_total_score"]] %||% 0,
    winter = row[["winter_total_score"]] %||% 0,
    convective = row[["convective_total_score"]] %||% 0,
    fire = row[["fire_total_score"]] %||% 0,
    heat = row[["heat_total_score"]] %||% 0,
    cold = row[["cold_total_score"]] %||% 0,
    air = row[["air_total_score"]] %||% 0,
    radiation = row[["radiation_total_score"]] %||% 0,
    seismic = row[["seismic_total_score"]] %||% 0,
    wind = row[["wind_total_score"]] %||% 0,
    temperature = row[["temp_risk_score"]] %||% 0,
    precipitation = row[["pop_risk_score"]] %||% 0
  )
  top <- names(which.max(candidates))
  if (max(candidates, na.rm = TRUE) <= 0) return("All clear.")
  switch(top,
    flood = if (!is.null(row[["flood_reason_text"]]) && !is.na(row[["flood_reason_text"]]) && nzchar(as.character(row[["flood_reason_text"]]))) as.character(row[["flood_reason_text"]]) else "Flood risk elevated by government flood guidance, precipitation, or river conditions.",
    winter = "Winter weather risk elevated by snow, ice, wind, or temperature conditions.",
    convective = if (!is.null(row[["convective_reason_text"]]) && !is.na(row[["convective_reason_text"]]) && nzchar(as.character(row[["convective_reason_text"]]))) as.character(row[["convective_reason_text"]]) else "Thunderstorm, hail, or severe convective risk is the primary environmental risk.",
    fire = "Fire risk elevated by official fire-weather guidance.",
    heat = "Heat risk elevated by temperature stress or UV exposure.",
    cold = "Cold risk elevated by freezing, wind chill, or winter exposure.",
    air = "Air-quality or smoke-related risk is the primary environmental risk.",
    radiation = if (!is.null(row[["radiation_reason_text"]]) && !is.na(row[["radiation_reason_text"]]) && nzchar(as.character(row[["radiation_reason_text"]]))) as.character(row[["radiation_reason_text"]]) else "Radiation exposure risk elevated by UV or radiological conditions.",
    seismic = if (!is.null(row[["seismic_event_text"]]) && !is.na(row[["seismic_event_text"]]) && nzchar(as.character(row[["seismic_event_text"]]))) as.character(row[["seismic_event_text"]]) else "Recent seismic activity is the primary environmental risk.",
    wind = "Wind-related risk elevated by official guidance or forecast wind.",
    "Government environmental risk elevated."
  )
}

# Builds an n x 10 matrix of per-zip family totals (wind, flood, ..., seismic) used as input to noisy_or_combine.
environmental_family_matrix <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) {
    return(matrix(numeric(0), nrow = 0, ncol = 10))
  }
  cbind(
    wind = zips$wind_total_score %||% 0,
    flood = zips$flood_total_score %||% 0,
    winter = zips$winter_total_score %||% 0,
    convective = zips$convective_total_score %||% 0,
    fire = zips$fire_total_score %||% 0,
    heat = zips$heat_total_score %||% 0,
    cold = zips$cold_total_score %||% 0,
    air = zips$air_total_score %||% 0,
    radiation = zips$radiation_total_score %||% 0,
    seismic = zips$seismic_total_score %||% 0
  )
}

# Returns the canonical noisy-OR weight vector (per-family multipliers applied before combining) used by the environmental risk equation.
environmental_family_weights <- function() {
  c(
    wind = 0.64,
    flood = 0.96,
    winter = 0.88,
    convective = 0.92,
    fire = 0.74,
    heat = 0.70,
    cold = 0.66,
    air = 0.60,
    radiation = 0.52,
    seismic = 0.78
  )
}

# Returns the human-readable description of the noisy-OR family combination used in the methodology popup.
environmental_risk_equation_text <- function() {
  paste(
    "Normalized environmental risk uses a damped noisy-OR across the main family totals:",
    "wind, flood, winter, convective, fire, heat, cold, air, radiation, and seismic.",
    "Temperature and precipitation do not enter the final score as standalone families;",
    "they feed the relevant family totals such as winter, flood, wind, convective, and heat.",
    "Alerts contribute through each family's capped alert-support term instead of acting like a separate statewide multiplier."
  )
}

# Why: combine independent family probabilities into one global "any family
# is bad" score using the standard noisy-OR formula 1 - prod(1 - w_j*x_ij).
# What: returns a length-n numeric vector in [0,1] from an n x k score
# matrix and optional length-k weights vector.
# How: clamps the matrix to [0,1] (NaN -> 0), normalises weights to [0,1]
# (default 1), then iterates columns multiplying keep_prob by (1 - w*x).
# When: the heart of combine_environmental_risk_score; called once per
# build pass over the per-ZIP family matrix.
# Impact: changing weights here shifts the relative pull of each family on
# the final environmental fill; the noisy-OR shape is what makes multiple
# moderate hazards combine into a high overall score.
noisy_or_combine <- function(score_matrix, weights = NULL) {
  if (is.null(score_matrix) || length(score_matrix) == 0) return(numeric(0))
  score_matrix <- as.matrix(score_matrix)
  if (is.null(dim(score_matrix))) {
    score_matrix <- matrix(score_matrix, ncol = 1L)
  }
  rows <- NROW(score_matrix)
  cols <- NCOL(score_matrix)
  if (!is.finite(rows) || rows < 1L || !is.finite(cols) || cols < 1L) return(rep(0, max(rows %||% 0L, 0L)))
  storage.mode(score_matrix) <- "double"
  score_matrix[!is.finite(score_matrix)] <- 0
  score_matrix[score_matrix < 0] <- 0
  score_matrix[score_matrix > 1] <- 1
  if (is.null(weights)) {
    weights <- rep(1, cols)
  } else {
    weights <- safe_numeric(weights)
    if (length(weights) != cols) weights <- rep(1, cols)
    weights[!is.finite(weights)] <- 1
    weights <- pmin(1, pmax(0, weights))
  }
  keep_prob <- rep(1, rows)
  for (j in seq_len(cols)) {
    keep_prob <- keep_prob * (1 - pmin(1, weights[j] * score_matrix[, j]))
  }
  pmin(1, pmax(0, 1 - keep_prob))
}

# Convenience: noisy_or_combine of environmental_family_matrix(zips) with environmental_family_weights() - the canonical environmental score.
combine_environmental_risk_score <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) return(numeric(0))
  family_matrix <- environmental_family_matrix(zips)
  noisy_or_combine(family_matrix, weights = environmental_family_weights())
}

# Why: the polygon fill colour depends on which "primary map" the user picked
# (environmental composite, single hazard, or hazard combination).
# What: returns a clamped [0,1] numeric vector of fill scores per ZIP for
# the chosen primary_map.
# How: dispatches on primary_map and reads the appropriate *_total_score
# column (or pmax of two columns for compound maps like "precipitation").
# When: called by build_view.R when computing the fill colour vector for
# the leaflet polygon layer.
# Impact: adding a new primary map requires extending this switch and the
# PRIMARY_MAP_CHOICES list.
compute_primary_fill_score <- function(zips, primary_map = DEFAULT_PRIMARY_MAP) {
  primary_map <- normalize_primary_map(primary_map)
  if (is.null(zips) || nrow(zips) == 0) return(numeric(0))
  fill_score <- switch(
    primary_map,
    environmental = zips$normalized_risk_score %||% rep(0, nrow(zips)),
    temperature = zips$temp_risk_score %||% rep(0, nrow(zips)),
    wind = zips$wind_total_score %||% zips$wind_risk_score %||% rep(0, nrow(zips)),
    precipitation = pmax(zips$pop_risk_score %||% 0, 0.70 * (zips$qpf_risk_score %||% 0), na.rm = TRUE),
    qpf_flood = zips$flood_total_score %||% rep(0, nrow(zips)),
    winter = zips$winter_total_score %||% rep(0, nrow(zips)),
    fire = zips$fire_total_score %||% rep(0, nrow(zips)),
    convective = zips$convective_total_score %||% rep(0, nrow(zips)),
    heat = zips$heat_total_score %||% rep(0, nrow(zips)),
    cold = zips$cold_total_score %||% rep(0, nrow(zips)),
    air = zips$air_total_score %||% rep(0, nrow(zips)),
    radiation = zips$radiation_total_score %||% rep(0, nrow(zips)),
    seismic = zips$seismic_total_score %||% rep(0, nrow(zips)),
    rep(0, nrow(zips))
  )
  fill_score <- safe_numeric(fill_score)
  fill_score[!is.finite(fill_score)] <- 0
  pmin(1, pmax(0, fill_score))
}

# Why: a ZIP next to a "red" ZIP often shares the same hazard but has not
# yet accumulated enough score; we boost neighbours so the user sees the
# implied danger.
# What: returns zips with normalized_risk_score boosted (capped by the
# source neighbour) and proximity_boosted/base_risk_score columns added.
# How: identifies red ZIPs (> RISK_RED_MIN), looks up the neighbour graph,
# and for each non-red neighbour scales its score by 1.5 capped at the max
# source neighbour's score.
# When: called near the end of the score pipeline, after all family totals
# but before display.
# Impact: too aggressive boosting paints whole regions red; the cap by
# source neighbour prevents runaway propagation.
apply_proximity_boost <- function(zips) {
  zips$proximity_boosted <- FALSE
  zips$base_risk_score <- zips$normalized_risk_score

  red_idx <- which(is.finite(zips$normalized_risk_score) & zips$normalized_risk_score > RISK_RED_MIN)
  if (length(red_idx) == 0) return(zips)

  neighbors <- get_zip_neighbors()
  red_neighbors <- unique(unlist(neighbors[red_idx], use.names = FALSE))
  red_neighbors <- red_neighbors[is.finite(red_neighbors)]
  boost_idx <- setdiff(as.integer(red_neighbors), red_idx)

  if (length(boost_idx) > 0) {
    capped_scores <- zips$normalized_risk_score[boost_idx]
    for (i in seq_along(boost_idx)) {
      idx <- boost_idx[i]
      source_red_idx <- red_idx[vapply(
        red_idx,
        function(red_i) idx %in% as.integer(neighbors[[red_i]] %||% integer(0)),
        logical(1)
      )]
      max_source_score <- if (length(source_red_idx) == 0) 1 else max(zips$normalized_risk_score[source_red_idx], na.rm = TRUE)
      if (!is.finite(max_source_score)) max_source_score <- 1
      capped_scores[i] <- min(max_source_score, pmin(1, zips$normalized_risk_score[idx] * 1.5))
    }
    zips$normalized_risk_score[boost_idx] <- capped_scores
    zips$proximity_boosted[boost_idx] <- capped_scores > zips$base_risk_score[boost_idx]
  }

  zips
}
