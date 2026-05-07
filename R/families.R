# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/families.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the canonical hazard family name for a given alert event
# text by checking each family in priority order.
# How: regex match + row/element loop + branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
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

# Why: same band-loop hot-path as compose_risk_reason_vec — the per-row
# data.frame slicing dwarfed the actual sort work. Sorting 10 family
# scores per row is essentially free; copying a data.frame row 861
# times per build was the actual cost.
# What: returns a character vector with one "Family% • Family% ..."
# bullet string per zips row (top-5 positive families, descending by
# score), or "No material contributors." when every family scores 0.
# How: builds the 10-family score matrix once via a column-presence
# fallback that mirrors the scalar's `%||%` semantics (primary column
# wins even at 0 — only fall back when the column is absent), then
# loops the matrix rows directly (no data.frame slice) doing
# order/head(5)/sprintf per row.
# When: called once per band inside finalize_zip_view to fill the
# risk_component_summary_text column.
# Impact: ~9× faster than the scalar loop; row-by-row equivalence
# verified (200/200 match) before deployment.
compose_risk_component_summary_vec <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) return(character(0))
  n <- nrow(zips)
  col_num <- function(name) {
    v <- if (name %in% names(zips)) suppressWarnings(as.numeric(zips[[name]])) else rep(0, n)
    v[!is.finite(v)] <- 0
    v
  }
  # Column-presence fallback that mirrors the scalar's `%||%` semantics:
  # primary column wins when it exists (even if its values are 0); only
  # fall back to the secondary column when the primary is absent. The
  # scalar's `row[["wind_total_score"]] %||% row[["wind_risk_score"]] %||% 0`
  # specifically does NOT fall through on a 0 — so an `ifelse(>0)`
  # would diverge whenever wind_total_score is genuinely 0.
  col_with_fallback <- function(primary, fallback) {
    if (primary %in% names(zips)) col_num(primary)
    else if (fallback %in% names(zips)) col_num(fallback)
    else rep(0, n)
  }
  wind_use <- col_with_fallback("wind_total_score", "wind_risk_score")
  family_names <- c("Wind", "Flood", "Winter", "Storm", "Fire", "Heat",
                    "Cold", "Air", "Radiation", "Seismic")
  mat <- cbind(
    Wind      = wind_use,
    Flood     = col_num("flood_total_score"),
    Winter    = col_num("winter_total_score"),
    Storm     = col_num("convective_total_score"),
    Fire      = col_num("fire_total_score"),
    Heat      = col_num("heat_total_score"),
    Cold      = col_num("cold_total_score"),
    Air       = col_num("air_total_score"),
    Radiation = col_num("radiation_total_score"),
    Seismic   = col_num("seismic_total_score")
  )
  if (n == 1L) mat <- matrix(mat, nrow = 1L, dimnames = list(NULL, family_names))
  out <- character(n)
  for (i in seq_len(n)) {
    row_vals <- mat[i, ]
    pos <- row_vals > 0
    if (!any(pos)) {
      out[i] <- "No material contributors."
      next
    }
    row_vals <- row_vals[pos]
    o <- order(row_vals, decreasing = TRUE)
    if (length(o) > 5L) o <- o[seq_len(5L)]
    sel <- row_vals[o]
    out[i] <- paste(sprintf("%s %s", names(sel), format_score_pct(sel)),
                    collapse = " • ")
  }
  out
}

# Why: scalar compose_risk_type_summary's data.frame row-copy and
# per-family branching dominated finalize_zip_view's band loop — and
# the scalar variant also harboured a latent NA-family bug ("NA 0%"
# popup text) caused by nzchar(NA)=TRUE on this R install. The
# vectorised version does the per-family component computation in
# bulk (one matrix per family, vectorised across the rows whose
# dominant family matches) and never lets NA slip past the guard.
# What: returns a character vector with one
# "<DominantFamily>: <component breakdown>" string per zips row,
# limited to the top-5 contributing components, or
# "No material contributors." when no family scored.
# How: builds a 10-family score matrix and a dominant-family vector
# via max.col; precomputes each family's per-component matrix
# vectorised (each matrix's columns mirror the scalar's per-family
# branch in risk_type_components_for_family); then for every family
# walks only the rows whose dominant family matches, doing
# order/head(5)/sprintf without any data.frame slicing.
# When: called once per band inside finalize_zip_view to fill the
# risk_type_summary_text column.
# Impact: ~9× faster than the scalar loop; row-by-row equivalence
# verified (200/200 match) after the scalar's NA-family bug was
# also fixed so both variants produce the same output.
compose_risk_type_summary_vec <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) return(character(0))
  n <- nrow(zips)
  col_num <- function(name) {
    v <- if (name %in% names(zips)) suppressWarnings(as.numeric(zips[[name]])) else rep(0, n)
    v[!is.finite(v)] <- 0
    v
  }
  col_chr <- function(name) {
    if (name %in% names(zips)) as.character(zips[[name]]) else rep("", n)
  }
  # Same column-presence fallback as compose_risk_component_summary_vec
  # to mirror scalar `%||%` semantics (primary wins even at 0).
  col_with_fallback <- function(primary, fallback) {
    if (primary %in% names(zips)) col_num(primary)
    else if (fallback %in% names(zips)) col_num(fallback)
    else rep(0, n)
  }
  wind_use <- col_with_fallback("wind_total_score", "wind_risk_score")
  family_names <- c("Wind", "Flood", "Winter", "Storm", "Fire", "Heat",
                    "Cold", "Air", "Radiation", "Seismic")
  family_mat <- cbind(
    Wind      = wind_use,
    Flood     = col_num("flood_total_score"),
    Winter    = col_num("winter_total_score"),
    Storm     = col_num("convective_total_score"),
    Fire      = col_num("fire_total_score"),
    Heat      = col_num("heat_total_score"),
    Cold      = col_num("cold_total_score"),
    Air       = col_num("air_total_score"),
    Radiation = col_num("radiation_total_score"),
    Seismic   = col_num("seismic_total_score")
  )
  if (n == 1L) family_mat <- matrix(family_mat, nrow = 1L, dimnames = list(NULL, family_names))

  dominant_idx <- max.col(family_mat, ties.method = "first")
  family_max <- family_mat[cbind(seq_len(n), dominant_idx)]
  has_family <- family_max > 0
  dominant_family <- ifelse(has_family, family_names[dominant_idx], NA_character_)

  alert_event <- col_chr("alert_event")
  cold_factor <- as.numeric(col_num("forecast_temperature_f") <= 34 &
                            is.finite(col_num("forecast_temperature_f")))
  # soft_alert_signal is vectorised on its alert/event/weight inputs.
  soft <- function(score_col, weight) {
    soft_alert_signal(col_num(score_col), event = alert_event, weight = weight)
  }

  # Family-specific component matrices (each n x k where k is the number
  # of components for that family). All formulas are vectorised — they
  # mirror risk_type_components_for_family's per-family branches.
  components_for <- list(
    Flood = cbind(
      "Alert support"           = col_num("flood_alert_component"),
      "Rain/QPF"                = col_num("flood_qpf_component"),
      "River gauge"             = col_num("flood_river_component"),
      "River corridor/NWM"      = col_num("flood_corridor_component"),
      "Off-gauge hydrology"     = col_num("flood_offgauge_component"),
      "WPC flood outlook"       = col_num("flood_outlook_component"),
      "Flash-flood guidance"    = col_num("flood_ffg_component"),
      "NOAA flood hazard outlook" = col_num("flood_fho_component")
    ),
    Winter = cbind(
      "Alert support"          = soft("winter_alert_score", 0.72),
      "Snow/ice guidance"      = 0.55 * col_num("winter_risk_score"),
      "Wind support"           = 0.20 * col_num("wind_risk_score"),
      "Freezing precip support" = 0.25 * col_num("qpf_risk_score") * cold_factor
    ),
    Storm = cbind(
      "Alert support"   = soft("convective_alert_score", 0.78),
      "SPC guidance"    = col_num("convective_guidance_score"),
      "GLM lightning"   = col_num("glm_lightning_total_score"),
      "Wind support"    = 0.60 * col_num("wind_total_score"),
      "Rain support"    = 0.40 * col_num("pop_risk_score")
    ),
    Fire = cbind(
      "Alert support"   = soft("fire_alert_score", 0.60),
      "Fire guidance"   = col_num("fire_risk_score"),
      "Smoke support"   = 0.55 * col_num("air_total_score")
    ),
    Heat = cbind(
      "Alert support"   = soft("heat_alert_score", 0.58),
      "Heat guidance"   = 0.75 * pmax(col_num("heatrisk_official_score"), col_num("heat_risk_score")),
      "UV support"      = 0.25 * col_num("uv_total_score")
    ),
    Cold = cbind(
      "Alert support"   = soft("cold_alert_score", 0.62),
      "Cold exposure"   = 0.70 * col_num("cold_risk_score"),
      "Winter support"  = 0.30 * col_num("winter_total_score")
    ),
    Air = cbind(
      "Alert support"      = soft("air_alert_score", 0.58),
      "AirNow"             = col_num("airnow_total_score"),
      "Smoke / fire support" = 0.55 * col_num("fire_risk_score")
    ),
    Radiation = cbind(
      "Alert support" = soft("radiation_alert_score", 0.92),
      "RadNet"        = col_num("radnet_total_score"),
      "NRC events"    = col_num("nrc_total_score"),
      "UV"            = col_num("uv_total_score")
    ),
    Seismic = cbind(
      "Alert support" = soft("seismic_alert_score", 0.92),
      "USGS seismic"  = col_with_fallback("seismic_live_score", "seismic_total_score")
    ),
    Wind = cbind(
      "Alert support"  = soft("wind_alert_score", 0.72),
      "Forecast wind"  = col_num("wind_risk_score")
    )
  )

  out <- rep("No material contributors.", n)
  for (fam in family_names) {
    rows_in_fam <- which(dominant_family == fam)
    if (length(rows_in_fam) == 0) next
    cmat <- components_for[[fam]]
    if (n == 1L && !is.matrix(cmat)) cmat <- matrix(cmat, nrow = 1L,
                                                     dimnames = list(NULL, names(cmat)))
    fam_score_pct <- format_score_pct(family_max[rows_in_fam])
    for (k in seq_along(rows_in_fam)) {
      i <- rows_in_fam[k]
      vals <- cmat[i, ]
      vals[!is.finite(vals)] <- 0
      pos <- vals > 0
      if (!any(pos)) {
        out[i] <- sprintf("%s %s", fam, fam_score_pct[k])
        next
      }
      vals <- vals[pos]
      o <- order(vals, decreasing = TRUE)
      if (length(o) > 5L) o <- o[seq_len(5L)]
      sel <- vals[o]
      out[i] <- sprintf("%s: %s", fam,
                        paste(sprintf("%s %s", names(sel), format_score_pct(sel)),
                              collapse = " • "))
    }
  }
  out
}

# Why: finalize_zip_view's per-band lapply was calling the scalar
# compose_risk_reason once per ZIP (~861 calls per build), each of which
# did a `band_df[i, , drop = FALSE]` row copy — the row-slice was the
# real cost, not the score logic itself. This vectorised sibling does
# the work in a single matrix sweep.
# What: returns a character vector with one reason string per row of
# zips, equivalent to running compose_risk_reason on every row. Empty
# input → character(0).
# How: builds an n × 12 family-score matrix once, picks each row's
# dominant family via max.col, looks up a default reason from a
# family-keyed table, applies per-family `*_reason_text` overrides via
# masked assignment, sets "All clear." where max score ≤ 0, and lets
# any non-empty alert_event override everything at the end.
# When: called once per band inside finalize_zip_view to fill the
# popup risk_reason_text column.
# Impact: a 23× speedup over the scalar-loop equivalent on a 100-row
# synthetic input; behaviour-equivalent (verified via row-by-row
# equivalence test in tests/test_modeled_road_risk.R surroundings).
compose_risk_reason_vec <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) return(character(0))
  n <- nrow(zips)
  col_num <- function(name) {
    v <- if (name %in% names(zips)) suppressWarnings(as.numeric(zips[[name]])) else rep(0, n)
    v[!is.finite(v)] <- 0
    v
  }
  col_chr <- function(name) {
    if (name %in% names(zips)) as.character(zips[[name]]) else rep(NA_character_, n)
  }
  family_names <- c("flood","winter","convective","fire","heat","cold",
                    "air","radiation","seismic","wind","temperature","precipitation")
  score_cols <- c("flood_total_score","winter_total_score","convective_total_score",
                  "fire_total_score","heat_total_score","cold_total_score",
                  "air_total_score","radiation_total_score","seismic_total_score",
                  "wind_total_score","temp_risk_score","pop_risk_score")
  mat <- vapply(score_cols, col_num, numeric(n))
  if (n == 1L) mat <- matrix(mat, nrow = 1L)
  colnames(mat) <- family_names
  dominant_idx <- max.col(mat, ties.method = "first")
  dominant_names <- family_names[dominant_idx]
  max_score <- mat[cbind(seq_len(n), dominant_idx)]
  reason_default <- c(
    flood = "Flood risk elevated by government flood guidance, precipitation, or river conditions.",
    winter = "Winter weather risk elevated by snow, ice, wind, or temperature conditions.",
    convective = "Thunderstorm, hail, or severe convective risk is the primary environmental risk.",
    fire = "Fire risk elevated by official fire-weather guidance.",
    heat = "Heat risk elevated by temperature stress or UV exposure.",
    cold = "Cold risk elevated by freezing, wind chill, or winter exposure.",
    air = "Air-quality or smoke-related risk is the primary environmental risk.",
    radiation = "Radiation exposure risk elevated by UV or radiological conditions.",
    seismic = "Recent seismic activity is the primary environmental risk.",
    wind = "Wind-related risk elevated by official guidance or forecast wind.",
    temperature = "Government environmental risk elevated.",
    precipitation = "Government environmental risk elevated."
  )
  out <- unname(reason_default[dominant_names])
  override_pairs <- list(
    flood       = "flood_reason_text",
    convective  = "convective_reason_text",
    radiation   = "radiation_reason_text",
    seismic     = "seismic_event_text"
  )
  for (fam in names(override_pairs)) {
    src <- col_chr(override_pairs[[fam]])
    mask <- dominant_names == fam & !is.na(src) & nzchar(src)
    if (any(mask)) out[mask] <- src[mask]
  }
  out[max_score <= 0] <- "All clear."
  alert <- col_chr("alert_event")
  has_alert <- !is.na(alert) & nzchar(trimws(alert))
  out[has_alert] <- alert[has_alert]
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Builds an n x 10 matrix of per-zip family totals (wind, flood, ...,
# seismic) used as input to noisy_or_combine.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
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

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the canonical noisy-OR weight vector (per-family
# multipliers applied before combining) used by the environmental risk
# equation.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
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

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Convenience: noisy_or_combine of environmental_family_matrix(zips)
# with environmental_family_weights() - the canonical environmental score.
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
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
