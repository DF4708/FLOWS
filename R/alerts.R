# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/alerts.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: notice cards have very limited space, so each summary needs to be one
# tidy sentence not exceeding the visual envelope.
# What: returns the first sentence of text trimmed to max_chars (with a
# trailing "..." if cut), or a placeholder when text is empty.
# How: collapses whitespace, splits on sentence boundaries, takes the first
# part, and substr-cuts if too long.
# When: used by fetch_wisconsin_alerts and build_notice_cards when shaping
# the notice list for display.
# Impact: changing max_chars resizes every notice card layout; the splitter
# regex must still cope with abbreviations gracefully.
truncate_sentence <- function(text, max_chars = 120) {
  if (is.null(text) || length(text) == 0 || is.na(text) || !nzchar(trimws(text))) {
    return("No active government notice summary available.")
  }
  text <- gsub("[\r\n\t]+", " ", text)
  text <- gsub("\\s+", " ", text, perl = TRUE)
  text <- trimws(text)
  parts <- unlist(strsplit(text, "(?<=[.!?])\\s+", perl = TRUE))
  first_sentence <- trimws(parts[1] %||% text)
  if (nchar(first_sentence) <= max_chars) return(first_sentence)
  paste0(substr(first_sentence, 1, max_chars - 1), "...")
}

# Why: the upstream payload arrives in an unstructured shape that the rest
# of the pipeline can't consume directly.
# What: Parses an ISO-8601 timestamp x as UTC POSIXct, returning
# POSIXct(NA) on empty/invalid input. Handles three common shapes that NWS
# / WI511 emit: "2026-05-05T05:00:00-05:00" (offset with colon — strptime's
# %z does NOT accept a colon, so strip it) "2026-05-05T05:00:00Z" (UTC
# marker) "2026-05-05 05:00:00" (no T, no offset — assume UTC) The previous
# implementation called as.POSIXct(x, tz = "UTC") with the default format
# and silently truncated to the date for any value that included a "T"
# separator or a colonized offset. That left every period in an hourly
# forecast resolving to the same midnight UTC, so pick_forecast_period
# selected the wrong "now" period — for ZIP 53713 this surfaced as a
# 22-hour-future 45 F reading on the live popup.
# How: guarded numeric coercion.
# When: called immediately after the upstream HTTP fetch resolves, before
# the result is handed to the scorer or shape converter.
# Impact: upstream schema drift is the main failure mode; the function
# tries multiple field-name spellings to absorb minor changes.
parse_iso_time <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x) || !nzchar(x)) return(as.POSIXct(NA, origin = "1970-01-01", tz = "UTC"))
  s <- as.character(x)
  # Normalise: replace "Z" with "+0000", and strip the ":" inside any
  # +HH:MM / -HH:MM offset suffix so strptime's %z can parse it.
  s <- sub("Z$", "+0000", s)
  s <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", s)
  fmts <- c(
    "%Y-%m-%dT%H:%M:%OS%z",
    "%Y-%m-%dT%H:%M:%S%z",
    "%Y-%m-%dT%H:%M:%OS",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%OS",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d"
  )
  parsed <- as.POSIXct(NA, origin = "1970-01-01", tz = "UTC")
  for (f in fmts) {
    p <- suppressWarnings(as.POSIXct(s, format = f, tz = "UTC"))
    if (!is.na(p)) { parsed <- p; break }
  }
  parsed
}

# Why: the NWS alert payload has many URL fields and most are useless to a
# human (the API "@id" returns JSON); we want one click-friendly destination.
# What: returns the best human-facing URL (specific weather.gov product or
# alert page, or a synthesised forecast.weather.gov product URL), or an
# alerts API URL as last resort.
# How: prefers explicit weather.gov product paths over generic alert pages;
# build_alert_text_product_url constructs a forecast.weather.gov URL from
# the AWIPSidentifier parameter when available.
# When: invoked once per feature in fetch_wisconsin_alerts when shaping the
# alert dataframe.
# Impact: a regression here makes the "View notice" link land on the NWS
# homepage or raw JSON, breaking the user's drill-down workflow.
resolve_human_alert_url <- function(props, fallback_id = NULL) {
  extract_alert_param <- function(props, key) {
    params <- props$parameters %||% list()
    if (is.null(params[[key]])) return(NA_character_)
    vals <- as.character(unlist(params[[key]], use.names = FALSE))
    vals <- vals[nzchar(trimws(vals))]
    if (length(vals) == 0) return(NA_character_)
    vals[1]
  }

  build_alert_text_product_url <- function(props) {
    awips_id <- trimws(as.character(extract_alert_param(props, "AWIPSidentifier") %||% ""))
    if (grepl("^[A-Z0-9]{6}$", awips_id)) {
      product_code <- substr(awips_id, 1, 3)
      office_code <- substr(awips_id, 4, 6)
      return(sprintf(
        "https://forecast.weather.gov/product.php?site=NWS&issuedby=%s&product=%s&format=CI&version=1&glossary=0",
        utils::URLencode(office_code, reserved = TRUE),
        utils::URLencode(product_code, reserved = TRUE)
      ))
    }
    if (nzchar(awips_id)) {
      return(sprintf(
        "https://www.weather.gov/wrh/TextProduct?product=%s",
        utils::URLencode(awips_id, reserved = TRUE)
      ))
    }
    NA_character_
  }

  candidates <- c(
    props$web %||% NA_character_,
    props$url %||% NA_character_,
    props[["@id"]] %||% NA_character_,
    props$id %||% NA_character_
  )
  param_web <- props$parameters$web %||% NULL
  if (!is.null(param_web)) candidates <- c(candidates, unlist(param_web, use.names = FALSE))
  candidates <- unique(stats::na.omit(as.character(candidates)))
  candidates <- candidates[grepl("^https?://", candidates, ignore.case = TRUE)]
  if (length(candidates) > 0) {
    normalized_candidates <- trimws(candidates)
    is_generic_weather_home <- grepl("^https?://(www\\.)?weather\\.gov/?$", normalized_candidates, ignore.case = TRUE)
    is_specific_alert <- grepl("/alerts/", normalized_candidates, ignore.case = TRUE)
    is_specific_weather_path <- grepl("^https?://([^/]+\\.)?weather\\.gov/.+", normalized_candidates, ignore.case = TRUE) &
      !grepl("^https?://(www\\.)?weather\\.gov/?$", normalized_candidates, ignore.case = TRUE)
    if (any(is_specific_weather_path & !is_specific_alert)) return(normalized_candidates[which(is_specific_weather_path & !is_specific_alert)[1]])
    if (any(is_specific_alert)) {
      product_url <- build_alert_text_product_url(props)
      if (nzchar(trimws(product_url %||% ""))) return(product_url)
      return(normalized_candidates[which(is_specific_alert)[1]])
    }
    non_homepage <- normalized_candidates[!is_generic_weather_home]
    if (length(non_homepage) > 0) {
      product_url <- build_alert_text_product_url(props)
      if (nzchar(trimws(product_url %||% ""))) return(product_url)
      return(non_homepage[1])
    }
    product_url <- build_alert_text_product_url(props)
    if (nzchar(trimws(product_url %||% ""))) return(product_url)
    return(candidates[1])
  }
  product_url <- build_alert_text_product_url(props)
  if (nzchar(trimws(product_url %||% ""))) return(product_url)
  fallback_id <- trimws(safe_string(fallback_id))
  if (grepl("^https?://", fallback_id, ignore.case = TRUE)) return(fallback_id)
  if (nzchar(fallback_id)) return(sprintf("https://api.weather.gov/alerts/%s", utils::URLencode(fallback_id, reserved = TRUE)))
  NA_character_
}

# Why: alert events don't have a single "severity tier"; we derive one from
# the event text using the NWS Watch/Warning/Alert convention.
# What: returns a character vector of "none"/"watch"/"warning"/"alert"
# matched element-wise to the input.
# How: lowercases, then tests for keywords in priority order (alert
# overrides warning, which overrides watch).
# When: used by alert_notification_color, cap_alert_score_for_notification,
# and any UI element that needs a tier label.
# Impact: changing the keyword regex re-tiers every alert color and score
# cap; "watch" is the safe default for unrecognised events.
alert_notification_level <- function(event = "") {
  txt <- tolower(trimws(safe_string(event)))
  out <- rep("none", length(txt))
  has_txt <- nzchar(txt)
  if (!any(has_txt)) return(out)
  out[has_txt] <- "watch"
  alert_idx <- has_txt & (
    grepl("emergency|evacuation|civil danger|nuclear|radiological", txt, perl = TRUE) |
      (grepl("tornado", txt, perl = TRUE) & !grepl("watch", txt, perl = TRUE))
  )
  out[has_txt & grepl("warning", txt, perl = TRUE)] <- "warning"
  out[has_txt & grepl("watch|advisory|statement", txt, perl = TRUE)] <- "watch"
  out[alert_idx] <- "alert"
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the hex color (green/amber/red/grey) matching
# alert_notification_level for each event in the vector.
# How: regex match.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
alert_notification_color <- function(event = "", default = "#666666") {
  level <- alert_notification_level(event)
  if (length(level) == 0) return(default)
  out <- rep(default, length(level))
  out[level %in% "watch"] <- "#2b7a0b"
  out[level %in% "warning"] <- "#8a6d00"
  out[level %in% "alert"] <- "#b30000"
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE per element when the event text indicates an
# in-progress life-threat (tornado, flash flood emergency, hurricane, etc.,
# excluding "watch").
# How: regex match.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
alert_is_active_event <- function(event = "") {
  txt <- tolower(trimws(safe_string(event)))
  has_txt <- nzchar(txt)
  active <- rep(FALSE, length(txt))
  active[has_txt] <- grepl("tornado|flash flood emergency|hurricane|wildfire|blizzard|earthquake|landspout|waterspout", txt[has_txt], perl = TRUE) &
    !grepl("watch", txt[has_txt], perl = TRUE)
  active
}

# Why: prevent low-tier alerts (advisories/watches) from saturating the map
# the way tornado warnings do.
# What: returns the alert score capped to the maximum allowed for its tier
# (1.00 for alert, 0.84 for warning, 0.62 for watch, 0.00 for none).
# How: computes alert_notification_level, builds a per-element cap vector,
# and returns pmin(score, cap).
# When: used inside soft_alert_signal and as a final clamp on score_nws_alert.
# Impact: changing caps re-balances how alerts compete with hazard scores
# in the composite map.
cap_alert_score_for_notification <- function(score, event = "") {
  score <- pmax(0, pmin(1, safe_numeric(score %||% 0)))
  level <- alert_notification_level(event)
  if (length(level) == 1L && length(score) > 1L) level <- rep(level, length(score))
  cap <- rep(0.62, max(length(score), length(level)))
  cap[level %in% "alert"] <- 1.00
  cap[level %in% "warning"] <- 0.84
  cap[level %in% "watch"] <- 0.62
  cap[level %in% "none"] <- 0.00
  if (length(score) == 1L && length(cap) > 1L) score <- rep(score, length(cap))
  pmin(score, cap)
}

# Why: turn a tier-capped alert score into a "soft" influence signal that
# can be blended with the hazard layer without overriding it outright.
# What: returns a 0..1 signal per element, boosted to at least 0.84 *
# bounded for active life-threat events.
# How: caps score by tier, multiplies by weight, then takes pmax with the
# 0.84 floor whenever alert_is_active_event is TRUE.
# When: called by blend_alert_signal during the composite-score build.
# Impact: weight controls how much voice alerts have in the final risk
# colour; the active-event override ensures tornadoes always show.
soft_alert_signal <- function(score, event = "", weight = 0.55) {
  bounded <- cap_alert_score_for_notification(score, event = event)
  weight <- pmax(0, pmin(1, safe_numeric(weight %||% 0.55)))
  signal <- bounded * weight
  active_event <- alert_is_active_event(event)
  if (length(active_event) == 1L && length(signal) > 1L) active_event <- rep(active_event, length(signal))
  active_event[!is.finite(active_event)] <- FALSE
  signal[active_event %in% TRUE] <- pmax(signal[active_event %in% TRUE], pmin(1, bounded[active_event %in% TRUE] * 0.84))
  pmin(1, pmax(0, signal))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Probabilistic OR-blend: returns 1 - (1 - base_signal) * (1 -
# soft_alert_signal(alert_score, event, alert_weight)).
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
blend_alert_signal <- function(base_signal, alert_score, event = "", alert_weight = 0.55) {
  base_signal <- pmax(0, pmin(1, safe_numeric(base_signal %||% 0)))
  alert_signal <- soft_alert_signal(alert_score, event = event, weight = alert_weight)
  1 - (1 - base_signal) * (1 - alert_signal)
}

# Why: collapse the NWS CAP fields (severity, urgency, certainty) plus event
# text into a single 0..1 score that drives map fill from alerts alone.
# What: returns a numeric 0..1 score (capped per tier) representing the
# alert's contribution to a ZIP's overall risk.
# How: looks each field up in a fixed score map, blends 0.50 sev + 0.28 urg
# + 0.22 cer, then enforces a tier-specific floor (e.g. 0.68 minimum for
# active events) and finally cap_alert_score_for_notification.
# When: called per ZIP-alert join when computing the alert score column.
# Impact: this is the table of weights for how the NWS classification maps
# into our normalised scale - tweaks here recolour the alert-driven map.
score_nws_alert <- function(event, severity, urgency, certainty) {
  event <- event %||% ""
  severity <- severity %||% "Unknown"
  urgency <- urgency %||% "Unknown"
  certainty <- certainty %||% "Unknown"
  level <- alert_notification_level(event)
  active_event <- isTRUE(alert_is_active_event(event))
  sev_map <- c(Extreme = 0.82, Severe = 0.62, Moderate = 0.44, Minor = 0.28, Unknown = 0.14)
  urg_map <- c(Immediate = 0.86, Expected = 0.62, Future = 0.30, Past = 0.06, Unknown = 0.14)
  cer_map <- c(Observed = 0.90, Likely = 0.68, Possible = 0.42, Unlikely = 0.12, Unknown = 0.14)
  sev <- if (!is.na(sev_map[severity])) unname(sev_map[severity]) else sev_map[["Unknown"]]
  urg <- if (!is.na(urg_map[urgency])) unname(urg_map[urgency]) else urg_map[["Unknown"]]
  cer <- if (!is.na(cer_map[certainty])) unname(cer_map[certainty]) else cer_map[["Unknown"]]
  blended <- 0.50 * sev + 0.28 * urg + 0.22 * cer
  bounded <- switch(
    level,
    alert = pmax(0.68, blended + if (active_event) 0.08 else 0.00),
    warning = pmax(0.42, blended * 0.92),
    watch = pmax(0.22, blended * 0.78),
    blended * 0.65
  )
  if (active_event) bounded <- pmax(bounded, 0.84)
  cap_alert_score_for_notification(bounded, event = event)
}

# Why: the canonical empty shape is needed wherever the upstream feed is
# missing or fails so downstream rbind / merge calls don't break the
# schema.
# What: Returns an empty CRS-4326 sf with the canonical alert columns -
# used as fallback when no alerts are active or fetch fails.
# How: sf geometry op.
# When: called as the fallback in every fetcher / compute step when the
# upstream feed is missing or returns no rows.
# Impact: changing the column set requires a matching update in every
# fetcher / compute step that returns this empty shape on failure.
empty_alert_sf <- function() {
  sf::st_sf(
    alert_id = character(),
    event = character(),
    severity = character(),
    urgency = character(),
    certainty = character(),
    areaDesc = character(),
    headline = character(),
    summary = character(),
    url = character(),
    sent = character(),
    onset = character(),
    ends = character(),
    geometry = sf::st_sfc(crs = 4326)
  )
}

# Why: produce the canonical Wisconsin NWS alert payload (sf, dataframe,
# notice list, zip mappings) with stale-while-revalidate semantics so the
# UI never shows nothing.
# What: returns a list with alerts_sf, alerts_df, notices, alert_zip_map,
# notice_zip_map, and an etag string.
# How: tries cache first, then on-disk snapshot, then NWS API; for each
# feature it builds the dataframe row, geometry, and learns zone counties;
# trims notices to NOTICE_LIMIT and persists to snapshot.
# When: the live alerts data source for the entire app, called from many
# server reactives.
# Impact: failure modes drop into stale-cache reads to keep the UI alive;
# a corrupt snapshot would leak through until ALERT_TTL_SECONDS expires.
fetch_wisconsin_alerts <- function(force_refresh = FALSE, timeout_seconds = 12L, max_tries = 1L, allow_stale = TRUE) {
  stale_cached <- cache_peek("alerts", TARGET_STATE)
  if (is.null(stale_cached) && isTRUE(allow_stale)) {
    stale_cached <- load_runtime_snapshot(ALERT_SNAPSHOT_PATH, max_age_seconds = 6 * 3600)
    if (!is.null(stale_cached)) {
      cache_put("alerts", TARGET_STATE, stale_cached, ttl_seconds = ALERT_TTL_SECONDS)
    }
  }
  if (!force_refresh) {
    cached <- cache_get("alerts", TARGET_STATE)
    if (!is.null(cached)) return(cached)
    if (isTRUE(allow_stale) && !is.null(stale_cached)) return(stale_cached)
  }
  payload <- safely(http_json(NWS_ALERTS_URL, timeout_seconds = timeout_seconds, max_tries = max_tries))
  if (is.null(payload)) {
    if (isTRUE(allow_stale) && !is.null(stale_cached)) return(stale_cached)
    out <- list(alerts_sf = empty_alert_sf(), alerts_df = data.frame(), notices = data.frame(), alert_zip_map = list(), notice_zip_map = list(), etag = Sys.time())
    cache_put("alerts", TARGET_STATE, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  features <- payload$features %||% list()
  if (length(features) == 0) {
    if (isTRUE(allow_stale) && !is.null(stale_cached)) return(stale_cached)
    out <- list(alerts_sf = empty_alert_sf(), alerts_df = data.frame(), notices = data.frame(), alert_zip_map = list(), notice_zip_map = list(), etag = Sys.time())
    cache_put("alerts", TARGET_STATE, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  rows <- vector("list", length(features))
  geoms <- vector("list", length(features))
  for (i in seq_along(features)) {
    feat <- features[[i]]
    props <- feat$properties %||% list()
    alert_id <- feat$id %||% props[["@id"]] %||% props$id %||% sprintf("alert-%s", i)
    sent <- props$sent %||% props$effective %||% props$onset %||% NA_character_
    summary_text <- truncate_sentence(props$description %||% props$instruction %||% props$headline %||% props$event)
    ugc_codes <- unique(as.character(unlist((props$geocode %||% list())$UGC %||% list(), use.names = FALSE)))
    same_codes <- unique(as.character(unlist((props$geocode %||% list())$SAME %||% list(), use.names = FALSE)))
    rows[[i]] <- data.frame(
      alert_id = as.character(alert_id),
      event = as.character(props$event %||% NA_character_),
      severity = as.character(props$severity %||% NA_character_),
      urgency = as.character(props$urgency %||% NA_character_),
      certainty = as.character(props$certainty %||% NA_character_),
      areaDesc = as.character(props$areaDesc %||% NA_character_),
      headline = as.character(props$headline %||% props$event %||% "Government notice"),
      summary = as.character(summary_text),
      url = as.character(resolve_human_alert_url(props, fallback_id = alert_id)),
      sent = as.character(sent),
      onset = as.character(props$onset %||% props$effective %||% NA_character_),
      ends = as.character(props$ends %||% props$expires %||% NA_character_),
      ugc_csv = paste(stats::na.omit(ugc_codes), collapse = "|"),
      same_csv = paste(stats::na.omit(same_codes), collapse = "|"),
      stringsAsFactors = FALSE
    )
    geoms[[i]] <- geojson_geometry_to_sfc(feat$geometry)
    learn_zone_counties_from_geometry(rows[[i]]$ugc_csv[1], geoms[[i]])
  }
  alert_df <- dplyr::bind_rows(rows)
  sfc <- do.call(c, geoms)
  alerts_sf_all <- sf::st_sf(alert_df, geometry = sfc, crs = 4326)
  alerts_sf_all <- ensure_crs_4326(alerts_sf_all)
  alerts_sf <- alerts_sf_all[!sf::st_is_empty(alerts_sf_all), , drop = FALSE]

  alert_zip_map <- setNames(vector("list", nrow(alert_df)), alert_df$alert_id)
  if (nrow(alert_df) > 0) {
    for (i in seq_len(nrow(alert_df))) {
      geom_i <- alerts_sf_all$geometry[i]
      alert_zip_map[[alert_df$alert_id[i]]] <- map_alert_record_to_zipcodes(alert_df[i, , drop = FALSE], geom_i)
    }
  }

  notice_df <- alert_df
  if (nrow(notice_df) > 0) {
    sent_num <- vapply(notice_df$sent, function(x) as.numeric(parse_iso_time(x)), numeric(1))
    notice_df$sent_time <- as.POSIXct(sent_num, origin = "1970-01-01", tz = "UTC")
    notice_df <- notice_df[order(notice_df$sent_time, decreasing = TRUE), , drop = FALSE]
    notice_df <- head(notice_df, NOTICE_LIMIT)
  }

  notice_zip_map <- list()
  if (nrow(notice_df) > 0) {
    notice_zip_map <- alert_zip_map[notice_df$alert_id]
    names(notice_zip_map) <- notice_df$alert_id
  }

  etag_parts <- paste(alert_df$alert_id, alert_df$sent, alert_df$ends, alert_df$ugc_csv, alert_df$same_csv, alert_df$areaDesc, sep = "~")
  out <- list(
    alerts_sf = alerts_sf,
    alerts_df = alert_df,
    notices = notice_df,
    alert_zip_map = alert_zip_map,
    notice_zip_map = notice_zip_map,
    etag = paste(etag_parts, collapse = "|")
  )
  cache_put("alerts", TARGET_STATE, out, ttl_seconds = ALERT_TTL_SECONDS)
  save_runtime_snapshot(ALERT_SNAPSHOT_PATH, out)
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns list(start, end) UTC bounds for an alert horizon ("live" ->
# [now, now], 24h/48h/72h -> sliding 24h windows).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
alert_horizon_window <- function(horizon_key = "live", reference_time = Sys.time()) {
  ref_time <- tryCatch(as.POSIXct(reference_time, tz = "UTC"), error = function(e) as.POSIXct(Sys.time(), tz = "UTC"))
  if (!is.finite(as.numeric(ref_time))) ref_time <- as.POSIXct(Sys.time(), tz = "UTC")
  if (identical(horizon_key %||% "live", "24h")) {
    return(list(start = ref_time, end = ref_time + 24 * 3600))
  }
  if (identical(horizon_key %||% "live", "48h")) {
    return(list(start = ref_time + 24 * 3600, end = ref_time + 48 * 3600))
  }
  if (identical(horizon_key %||% "live", "72h")) {
    return(list(start = ref_time + 48 * 3600, end = ref_time + 72 * 3600))
  }
  list(start = ref_time, end = ref_time)
}

# Why: a single fetched alert payload is reused across horizons; we need to
# filter it down to whichever 24h window the user is viewing.
# What: returns a copy of payload with alerts_df, notices, alerts_sf, and
# zip maps trimmed to alerts whose [onset, ends] overlaps the horizon
# window.
# How: parses sent/onset/ends timestamps, keeps rows where onset is before
# window_end and ends is after window_start, rebuilds notices from the
# filtered set sorted by sent_time.
# When: called between fetch_wisconsin_alerts and any per-horizon alert
# rendering (notice cards, alert overlays).
# Impact: a too-aggressive filter hides relevant warnings; off-by-one on
# sent vs onset is a frequent source of "where did my alert go?" bugs.
filter_alert_payload_for_horizon <- function(payload, horizon_key = "live", reference_time = Sys.time(), notice_limit = NOTICE_LIMIT) {
  payload <- payload %||% list()
  alerts_df <- payload$alerts_df %||% data.frame()
  if (!nrow(alerts_df)) {
    payload$alerts_df <- data.frame()
    payload$notices <- data.frame()
    payload$alerts_sf <- empty_alert_sf()
    payload$alert_zip_map <- list()
    payload$notice_zip_map <- list()
    return(payload)
  }

  sent_num <- vapply(alerts_df$sent %||% rep(NA_character_, nrow(alerts_df)), function(x) as.numeric(parse_iso_time(x)), numeric(1))
  onset_num <- vapply(alerts_df$onset %||% rep(NA_character_, nrow(alerts_df)), function(x) as.numeric(parse_iso_time(x)), numeric(1))
  ends_num <- vapply(alerts_df$ends %||% rep(NA_character_, nrow(alerts_df)), function(x) as.numeric(parse_iso_time(x)), numeric(1))
  onset_num[!is.finite(onset_num)] <- sent_num[!is.finite(onset_num)]

  window <- alert_horizon_window(horizon_key, reference_time = reference_time)
  window_start <- safe_numeric(window$start)
  window_end <- safe_numeric(window$end)
  if (!is.finite(window_start)) window_start <- safe_numeric(as.POSIXct(Sys.time(), tz = "UTC"))
  if (!is.finite(window_end)) window_end <- window_start

  keep_idx <- rep(TRUE, nrow(alerts_df))
  keep_idx <- keep_idx & (!is.finite(onset_num) | onset_num <= window_end)
  keep_idx <- keep_idx & (!is.finite(ends_num) | ends_num >= window_start)

  filtered_df <- alerts_df[keep_idx, , drop = FALSE]
  if (!nrow(filtered_df)) {
    payload$alerts_df <- filtered_df
    payload$notices <- filtered_df
    payload$alerts_sf <- empty_alert_sf()
    payload$alert_zip_map <- list()
    payload$notice_zip_map <- list()
    return(payload)
  }

  filtered_ids <- as.character(filtered_df$alert_id %||% character(0))
  filtered_map <- payload$alert_zip_map %||% list()
  filtered_map <- filtered_map[filtered_ids]
  names(filtered_map) <- filtered_ids

  filtered_sf <- payload$alerts_sf %||% empty_alert_sf()
  if (!is.null(filtered_sf) && nrow(filtered_sf) > 0 && "alert_id" %in% names(filtered_sf)) {
    filtered_sf <- filtered_sf[as.character(filtered_sf$alert_id) %in% filtered_ids, , drop = FALSE]
  } else {
    filtered_sf <- empty_alert_sf()
  }

  sent_num_filtered <- vapply(filtered_df$sent %||% rep(NA_character_, nrow(filtered_df)), function(x) as.numeric(parse_iso_time(x)), numeric(1))
  filtered_df$sent_time <- as.POSIXct(sent_num_filtered, origin = "1970-01-01", tz = "UTC")
  notice_df <- filtered_df[order(filtered_df$sent_time, decreasing = TRUE), , drop = FALSE]
  if (nrow(notice_df) > notice_limit) notice_df <- notice_df[seq_len(notice_limit), , drop = FALSE]
  notice_ids <- as.character(notice_df$alert_id %||% character(0))
  notice_zip_map <- filtered_map[notice_ids]
  names(notice_zip_map) <- notice_ids

  payload$alerts_df <- filtered_df
  payload$notices <- notice_df
  payload$alerts_sf <- filtered_sf
  payload$alert_zip_map <- filtered_map
  payload$notice_zip_map <- notice_zip_map
  payload
}

# Why: convert the filtered notice rows into renderable HTML cards with
# hover/click behaviour wired to Shiny inputs.
# What: returns a tagList of <div class="notice-card-..."> tags (or an
# "empty" placeholder div when there are no notices).
# How: per row, builds a notice_card_profile, formats sent_time, generates
# href + dismiss button + onmouseenter/leave handlers tying back to the
# Shiny session via setInputValue.
# When: rendered into the sidebar by the server.R notice list output.
# Impact: visual changes belong here; the data-* attributes are read by
# gomap.js to drive map highlight, so renaming them breaks interactivity.
build_notice_cards <- function(clickable = TRUE, hover_enabled = TRUE, payload = NULL) {
  if (is.null(payload)) payload <- fetch_wisconsin_alerts()
  notices <- payload$notices
  if (is.null(notices) || nrow(notices) == 0) return(shiny::div(class = "notice-stack-empty", "No Wisconsin alerts for this timeline."))
  cards <- lapply(
    seq_len(nrow(notices)),
    function(i) {
      row <- notices[i, , drop = FALSE]
      profile <- notice_card_profile(row$event, row$severity, row$urgency, row$certainty)
      sent_time <- parse_iso_time(row$sent)
      time_label <- if (is.na(sent_time)) "" else format(sent_time, "%b %d %I:%M %p", tz = "UTC")
      title_text <- row$headline %||% row$event %||% "Government notice"
      body_text <- truncate_sentence(row$summary %||% row$headline)
      href_val <- trimws(ifelse(is.na(row$url %||% NA_character_), "", safe_string(row$url)))
      attrs <- list(
        class = profile$class,
        `data-alert-id` = row$alert_id,
        `data-alert-risk-label` = profile$label,
        `data-alert-score` = sprintf("%.4f", profile$score),
        onmouseenter = if (hover_enabled) sprintf("Shiny.setInputValue('hover_notice_id','%s',{priority:'event'})", row$alert_id) else NULL,
        onmouseleave = if (hover_enabled) "Shiny.setInputValue('hover_notice_id','',{priority:'event'})" else NULL
      )
      link_tag <- do.call(
        shiny::tags$a,
        list(
          class = "notice-card-link",
          href = if (clickable && nzchar(href_val)) href_val else NULL,
          target = if (clickable && nzchar(href_val)) "_blank" else NULL,
          rel = if (clickable && nzchar(href_val)) "noopener noreferrer" else NULL,
          shiny::div(class = "notice-card-title", escape_html(title_text)),
          shiny::div(class = "notice-card-body", escape_html(body_text)),
          shiny::div(class = "notice-card-time", escape_html(time_label))
        )
      )
      close_tag <- shiny::tags$button(
        type = "button",
        class = "notice-card-close",
        title = "Dismiss alert",
        `aria-label` = "Dismiss alert",
        `data-alert-id` = row$alert_id,
        onclick = "event.preventDefault(); event.stopPropagation(); Shiny.setInputValue('dismiss_notice_id', this.dataset.alertId, {priority:'event'});",
        "X"
      )
      do.call(
        shiny::tags$div,
        c(attrs, list(
          close_tag,
          link_tag
        ))
      )
    }
  )
  do.call(shiny::tagList, cards)
}
