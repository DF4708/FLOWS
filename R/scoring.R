# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/scoring.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Maps 0..1 scores to "Transparent"/"Green"/"Yellow"/"Red" via the
# global RISK_*_MIN thresholds. Vectorised: callers that pass a long score
# vector (e.g. one entry per OSM road) used to wrap this in a vapply over
# thousands of rows; the inlined vectorised form is significantly faster on
# the road overlay's per-segment styling pass.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
risk_label_from_score <- function(score) {
  s <- suppressWarnings(as.numeric(score))
  out <- rep("Transparent", length(s))
  finite <- is.finite(s)
  out[finite & s >= RISK_GREEN_MIN  & s <  RISK_YELLOW_MIN] <- "Green"
  out[finite & s >= RISK_YELLOW_MIN & s <= RISK_RED_MIN]    <- "Yellow"
  out[finite & s >  RISK_RED_MIN]                           <- "Red"
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Applies a gamma curve to a 0..1 score so the legend devotes more
# visual space to the higher-risk end of the scale.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
risk_scale_position <- function(score, gamma = 1.45) {
  score <- pmax(0, pmin(1, safe_numeric(score)))
  score ^ gamma
}

# Why: the user-facing display needs a consistent rendering of this value
# across popups / summaries / legends.
# What: Formats a duration in minutes as "Nh Mm" / "Nh" / "M min" for ETA
# display, returning "ETA unavailable" for non-finite input.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: any change to the rendering shows up directly in popups / legends
# / summaries; keep callers' assumptions about output shape (e.g., "%s%%")
# stable.
format_duration_minutes <- function(minutes) {
  minutes <- safe_numeric(minutes %||% NA_real_)
  if (!is.finite(minutes) || minutes <= 0) return("ETA unavailable")
  total_minutes <- as.integer(round(minutes))
  hours <- total_minutes %/% 60L
  mins <- total_minutes %% 60L
  if (hours <= 0) return(sprintf("%d min", mins))
  if (mins == 0) return(sprintf("%dh", hours))
  sprintf("%dh %dm", hours, mins)
}

# Why: ZIP polygons need a constant-alpha fill colour driven by score so the
# leaflet layer renders consistently regardless of underlying data type.
# What: returns a character vector of "rgb(...)"-like strings (or fully
# transparent black) chosen by score band.
# How: clamps score to [0,1], iterates band thresholds, emits matching
# rgb() at alpha=128 for visible bands.
# When: called per ZIP row when building popups/polygon style on every
# refresh of the risk view.
# Impact: changing the alpha or palette shifts the visual identity of every
# layer; thresholds align with risk_label_from_score - keep them in sync.
risk_rgba <- function(score) {
  score <- pmax(0, pmin(1, score))
  cols <- vapply(
    score,
    function(x) {
      if (!is.finite(x) || x < RISK_GREEN_MIN) return(rgb(0, 0, 0, alpha = 0, maxColorValue = 255))
      if (x < RISK_YELLOW_MIN) return(rgb(46, 204, 113, alpha = 128, maxColorValue = 255))
      if (x <= RISK_RED_MIN) return(rgb(241, 196, 15, alpha = 128, maxColorValue = 255))
      rgb(220, 53, 69, alpha = 128, maxColorValue = 255)
    },
    character(1)
  )
  unname(cols)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns CSS hex colours
# ("transparent"/"#2ecc71"/"#f1c40f"/"#dc3545") for score bands. Vectorised
# so the road-overlay styling pass (~25k rows) does not run a per-row
# vapply.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
risk_rgb_hex <- function(score) {
  s <- pmax(0, pmin(1, suppressWarnings(as.numeric(score))))
  out <- rep("transparent", length(s))
  finite <- is.finite(s)
  out[finite & s >= RISK_GREEN_MIN  & s <  RISK_YELLOW_MIN] <- "#2ecc71"
  out[finite & s >= RISK_YELLOW_MIN & s <= RISK_RED_MIN]    <- "#f1c40f"
  out[finite & s >  RISK_RED_MIN]                           <- "#dc3545"
  out
}

# Why: the legend strip uses a continuous colour gradient, not the discrete
# polygon palette, so we interpolate between band anchors.
# What: returns a vector of hex colours by Lab-space-interpolating between
# white -> green -> yellow -> red -> dark crimson.
# How: locates each score's band and uses grDevices::colorRamp at the local
# fractional position to produce a smooth blend.
# When: invoked by legend_gradient_style when assembling the CSS gradient
# stop list shown in the legend.
# Impact: the visual smoothness of the legend depends entirely on this; any
# threshold change must mirror RISK_*_MIN to keep colour-band alignment.
legend_gradient_color_hex <- function(score) {
  score <- pmax(0, pmin(1, safe_numeric(score)))
  anchors <- c(0.00, RISK_GREEN_MIN, RISK_YELLOW_MIN, RISK_RED_MIN, 1.00)
  anchor_cols <- c("#ffffff", "#2ecc71", "#f1c40f", "#dc3545", "#7a1022")
  interp_one <- function(x) {
    if (!is.finite(x)) return("#ffffff")
    if (x <= anchors[1]) return(anchor_cols[1])
    if (x >= anchors[length(anchors)]) return(anchor_cols[length(anchor_cols)])
    idx <- max(which(anchors <= x))
    idx <- min(idx, length(anchors) - 1L)
    left <- anchors[idx]
    right <- anchors[idx + 1L]
    span <- max(right - left, 1e-9)
    t <- (x - left) / span
    ramp <- grDevices::colorRamp(anchor_cols[idx:(idx + 1L)], space = "Lab")
    rgb <- round(ramp(t)[1, ])
    grDevices::rgb(rgb[1], rgb[2], rgb[3], maxColorValue = 255)
  }
  unname(vapply(score, interp_one, character(1)))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Builds the inline CSS "background: linear-gradient(...)" string
# used by the legend strip, with stops at gamma-shaped positions.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
legend_gradient_style <- function(gamma = 1.45) {
  sample_scores <- sort(unique(c(seq(0, 1, by = 0.05), RISK_GREEN_MIN, RISK_YELLOW_MIN, RISK_RED_MIN, 1.0)))
  stop_positions <- 100 * risk_scale_position(sample_scores, gamma = gamma)
  stop_colors <- legend_gradient_color_hex(sample_scores)
  stops <- paste(sprintf("%s %.1f%%", stop_colors, stop_positions), collapse = ", ")
  paste0("background: linear-gradient(to right, ", stops, ");")
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Vectorised wrapper over piecewise_score with scalar (low, mid,
# high) thresholds.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
vector_piecewise_score <- function(values, low, mid, high) {
  vapply(values, function(v) piecewise_score(v, low, mid, high), numeric(1))
}

# Why: scoring per-ZIP requires per-row thresholds (one ZIP's "low" is another
# ZIP's "high") and looping piecewise_score is too slow for hot paths.
# What: returns a length-n numeric vector of 0..1 scores, fully vectorised
# across values and threshold vectors.
# How: pre-recycles inputs to common length, masks valid rows, and assigns
# piecewise contributions to green/yellow/red index slices in bulk.
# When: called by the per-zip risk builder for hazards (driving, AQ, etc.)
# whose thresholds are spatially varying.
# Impact: a threshold ordering bug here mis-bands an entire layer at once;
# the in-place assignment is what makes the live recompute interactive.
vector_piecewise_score_rowwise <- function(values, low, mid, high) {
  values <- safe_numeric(values)
  low <- safe_numeric(low)
  mid <- safe_numeric(mid)
  high <- safe_numeric(high)
  n <- max(length(values), length(low), length(mid), length(high))
  if (n <= 0) return(numeric(0))
  values <- rep_len(values, n)
  low <- rep_len(low, n)
  mid <- rep_len(mid, n)
  high <- rep_len(high, n)
  out <- rep(0, n)
  valid <- is.finite(values) & is.finite(low) & is.finite(mid) & is.finite(high) & values > 0
  if (!any(valid)) return(out)
  green_idx <- valid & values > low & values <= mid
  yellow_idx <- valid & values > mid & values <= high
  red_idx <- valid & values > high
  out[green_idx] <- RISK_GREEN_MIN + (RISK_YELLOW_MIN - RISK_GREEN_MIN) * ((values[green_idx] - low[green_idx]) / pmax(mid[green_idx] - low[green_idx], 1e-9))
  out[yellow_idx] <- RISK_YELLOW_MIN + (RISK_RED_MIN - RISK_YELLOW_MIN) * ((values[yellow_idx] - mid[yellow_idx]) / pmax(high[yellow_idx] - mid[yellow_idx], 1e-9))
  out[red_idx] <- pmin(1, RISK_RED_MIN + (1 - RISK_RED_MIN) * ((values[red_idx] - high[red_idx]) / pmax(high[red_idx], 1e-9)))
  out
}

# Why: the canonical risk-curve maps a raw value through three thresholds onto
# the global green/yellow/red [0,1] band so all hazards share one scale.
# What: returns a 0..1 score (clipped at 1) for a single scalar value.
# How: returns 0 below `low`, then linearly interpolates within each band
# (low->medium, medium->high, high->infinity) using shared band constants.
# When: used everywhere a scalar hazard reading needs a normalised score;
# vector wrappers above call this for non-rowwise inputs.
# Impact: this is the single place to change the meaning of low/medium/high
# thresholds - any edit ripples to every hazard score in the app.
piecewise_score <- function(value, low, medium, high) {
  if (!is.finite(value) || value <= 0) return(0)
  if (value <= low) return(0)
  if (value <= medium) return(RISK_GREEN_MIN + (RISK_YELLOW_MIN - RISK_GREEN_MIN) * ((value - low) / max(medium - low, 1e-9)))
  if (value <= high) return(RISK_YELLOW_MIN + (RISK_RED_MIN - RISK_YELLOW_MIN) * ((value - medium) / max(high - medium, 1e-9)))
  pmin(1, RISK_RED_MIN + (1 - RISK_RED_MIN) * ((value - high) / max(high, 1e-9)))
}

# Why: some inputs are "lower means worse" (e.g., FFG inches available before
# flooding), so the band ordering inverts.
# What: returns a 0..1 score for value with thresholds in descending order
# (low_risk > medium_risk > high_risk).
# How: mirror image of piecewise_score - returns 0 above low_risk, scales
# linearly down each band toward high_risk.
# When: used by score_ffg_inches and similar inverse hazards.
# Impact: misordered thresholds silently flip the polarity of an entire
# overlay; keep this function's API symmetric with piecewise_score.
inv_piecewise_score <- function(value, low_risk, medium_risk, high_risk) {
  if (!is.finite(value)) return(0)
  if (value >= low_risk) return(0)
  if (value >= medium_risk) return(RISK_GREEN_MIN + (RISK_YELLOW_MIN - RISK_GREEN_MIN) * ((low_risk - value) / max(low_risk - medium_risk, 1e-9)))
  if (value >= high_risk) return(RISK_YELLOW_MIN + (RISK_RED_MIN - RISK_YELLOW_MIN) * ((medium_risk - value) / max(medium_risk - high_risk, 1e-9)))
  pmin(1, RISK_RED_MIN + (1 - RISK_RED_MIN) * ((high_risk - value) / max(high_risk, 1e-9)))
}

# Why: temperature risk is symmetric - too cold and too hot both score above
# 0, with linear ramps to record extremes.
# What: returns a 0..1 risk for temp_f, 0 inside the comfort band, capped
# at 1 past the record low/high.
# How: branches on hot-side vs cold-side of comfort range and divides by
# the distance from comfort to record.
# When: feeds into the temperature component of the heat/cold totals when
# computing per-zip composite risk.
# Impact: bad comfort/record bounds shift the entire temperature curve;
# this is one of the few hazards where 0 is both possible and intentional.
temperature_risk <- function(temp_f, comfort_low_f, comfort_high_f, record_low_f, record_high_f) {
  if (!is.finite(temp_f)) return(0)
  if (temp_f >= comfort_low_f && temp_f <= comfort_high_f) return(0)
  if (temp_f < comfort_low_f) return(pmin(1, (comfort_low_f - temp_f) / max(comfort_low_f - record_low_f, 1e-9)))
  pmin(1, (temp_f - comfort_high_f) / max(record_high_f - comfort_high_f, 1e-9))
}
