# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# wi511_alerts.R - prose-alert scorer and zip-resolution helpers
# (zipcodes / counties / places / roadways / region aliases mentioned
# in alert text) plus the alert fetcher and per-ZIP signal builder.


# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps WI511 alert message + notes + flags to 0..1 SAFETY risk. Same
# safety-vs-throughput discipline as the message-sign and event scorers:
# operational-only text (flex / HOV / managed / express / ramp meter / toll
# plaza / special-event traffic) returns 0; bare "closed" needs road
# context; pure delay/restriction text is excluded.
# How: regex match.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_511_alert_risk <- function(message = "", notes = "", high_importance = FALSE, send_notification = FALSE) {
  text <- tolower(trimws(paste(message, notes, collapse = " | ")))
  if (!nzchar(text)) return(0)
  if (is_operational_only_511_text(text)) return(0)
  score <- 0
  if (grepl("flood|washout|bridge collapse|sinkhole|fire|hazmat|jackknife", text)) score <- max(score, 0.95)
  if (grepl("tornado|damaging wind|microburst|large hail|dust storm|haboob|severe thunderstorm warning", text, perl = TRUE)) score <- max(score, 0.92)
  if (grepl("road closed|highway closed|interstate closed|all lanes closed|emergency closure|impassable|do not use", text, perl = TRUE)) score <- max(score, 0.90)
  if (grepl("crash|incident|disabled vehicle|overturned", text)) score <- max(score, 0.60)
  if (grepl("slippery|ic[ey]|snow|winter|blowing snow|reduced visibility|fog|signal out|signal dark", text, perl = TRUE)) score <- max(score, 0.58)
  if (grepl("roadwork|construction|maintenance", text)) score <- max(score, 0.40)
  if (score == 0) return(0)
  if (isTRUE(high_importance)) score <- min(1, score + 0.10)
  if (isTRUE(send_notification)) score <- min(1, score + 0.05)
  pmin(1, score)
}


# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the unique 5-digit ZIP codes mentioned in text that exist
# in wi_zctas$zipcode.
# How: regex match + row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_zipcodes_from_text <- function(text) {
  txt <- safe_string(text)
  hits <- unique(unlist(regmatches(txt, gregexpr("\\b[0-9]{5}\\b", txt, perl = TRUE)), use.names = FALSE))
  hits <- hits[hits %in% wi_zctas$zipcode]
  unique(as.character(hits))
}


# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the unique zipcodes belonging to any WI county whose
# normalised name appears as a whole word in text.
# How: regex match + row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_county_zipcodes_from_text <- function(text) {
  txt <- normalize_match_text(text)
  if (!nzchar(txt)) return(character(0))
  county_names <- unique(as.character(wi_counties$NAME))
  matched <- county_names[vapply(
    county_names,
    function(nm) {
      nm_norm <- normalize_match_text(nm)
      nzchar(nm_norm) && grepl(paste0("\\b", regex_escape(nm_norm), "\\b"), txt, perl = TRUE)
    },
    logical(1)
  )]
  if (length(matched) == 0) return(character(0))
  unique(as.character(wi_zctas$zipcode[wi_zctas$county_name %in% matched]))
}


# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the unique zipcodes that intersect any place polygon whose
# normalised name appears as a whole word in text.
# How: regex match + sf geometry op + row/element loop + guarded numeric
# coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_place_zipcodes_from_text <- function(text) {
  txt <- normalize_match_text(text)
  if (!nzchar(txt)) return(character(0))
  places <- load_places()
  if (nrow(places) == 0 || !"NAME" %in% names(places)) return(character(0))
  place_names <- unique(as.character(places$NAME))
  matched <- place_names[vapply(
    place_names,
    function(nm) {
      nm_norm <- normalize_match_text(nm)
      nzchar(nm_norm) && grepl(paste0("\\b", regex_escape(nm_norm), "\\b"), txt, perl = TRUE)
    },
    logical(1)
  )]
  if (length(matched) == 0) return(character(0))
  place_hits <- places[places$NAME %in% matched, , drop = FALSE]
  inter <- suppressWarnings(sf::st_intersects(wi_zctas, place_hits))
  unique(as.character(wi_zctas$zipcode[lengths(inter) > 0]))
}


# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Uppercases x, replaces non-alphanumerics with single spaces, and
# collapses whitespace - used to canonicalise highway tokens.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_route_text <- function(x) {
  trimws(gsub("\\s+", " ", gsub("[^A-Za-z0-9]+", " ", toupper(safe_string(x)))))
}


# Why: WI511 alerts often mention "I-94" or "STH 29" but no county or ZIP;
# we map those tokens to the ZIP set that touches that highway.
# What: returns a unique character vector of zipcodes touching any
# matching road (capped at max_tokens roads to avoid blow-up).
# How: regex-extracts I-/US-/WI-/STH-/HWY- tokens, normalises each, fuzzy
# matches against load_wi_roads()$road_name (with HIGHWAY/STH aliasing),
# and pulls the precomputed road_zip lookup entries.
# When: called by resolve_511_region_zipcodes for each WI511 alert.
# Impact: a missing pattern (e.g., a future "CTH-X" county-trunk format)
# silently drops the alert from the affected ZIPs.
extract_roadway_zipcodes_from_text <- function(text, max_tokens = 8L) {
  txt <- toupper(safe_string(text))
  if (!nzchar(txt)) return(character(0))
  patt <- "\\b(?:I\\s*-?\\s*\\d+|US\\s*-?\\s*\\d+|WI\\s*-?\\s*\\d+|STH\\s*-?\\s*\\d+|HWY\\s*-?\\s*\\d+|HIGHWAY\\s+\\d+)\\b"
  raw_tokens <- unique(unlist(regmatches(txt, gregexpr(patt, txt, perl = TRUE)), use.names = FALSE))
  if (length(raw_tokens) == 0) return(character(0))
  roads <- load_wi_roads()
  lookup <- load_road_zip_lookup()
  if (nrow(roads) == 0 || length(lookup) == 0) return(character(0))
  road_norm <- normalize_route_text(roads$road_name)
  zip_hits <- character(0)
  for (tok in utils::head(raw_tokens, max_tokens)) {
    tok_norm <- normalize_route_text(tok)
    if (!nzchar(tok_norm)) next
    tok_alt <- gsub("\\bHIGHWAY\\b", "HWY", tok_norm)
    tok_alt2 <- gsub("\\bSTH\\b", "WI", tok_norm)
    idx <- grepl(paste0("(^| )", regex_escape(tok_norm), "( |$)"), road_norm, perl = TRUE) |
      grepl(paste0("(^| )", regex_escape(tok_alt), "( |$)"), road_norm, perl = TRUE) |
      grepl(paste0("(^| )", regex_escape(tok_alt2), "( |$)"), road_norm, perl = TRUE)
    if (!any(idx)) next
    zip_hits <- c(zip_hits, unlist(lookup[roads$road_id[idx]], use.names = FALSE))
  }
  zip_hits <- unique(as.character(zip_hits))
  zip_hits[zip_hits %in% wi_zctas$zipcode]
}


# Why: WI511 uses informal regional names ("northeastern", "south central")
# we want to translate into ZIP sets via a curated county-group table.
# What: returns the unique zipcodes for every county_group implied by the
# input tokens.
# How: hardcoded county_groups + alias_to_group tables; tokens hit the
# alias map and the matched group's counties feed wi_zctas$county_name.
# When: called by resolve_511_region_zipcodes.
# Impact: missing aliases here mean an alert tagged with a regional name
# but no specific roadway/county/place silently fails to map.
region_alias_zipcodes <- function(region_tokens) {
  tokens <- tolower(trimws(as.character(region_tokens %||% character(0))))
  tokens <- tokens[nzchar(tokens)]
  if (length(tokens) == 0) return(character(0))
  county_groups <- list(
    statewide = unique(as.character(wi_zctas$zipcode)),
    northwestern = c("Douglas", "Bayfield", "Ashland", "Iron", "Burnett", "Washburn", "Sawyer", "Price", "Rusk", "Barron", "Polk", "St. Croix"),
    northeastern = c("Door", "Kewaunee", "Brown", "Oconto", "Marinette", "Florence", "Forest", "Langlade", "Lincoln", "Oneida", "Vilas", "Menominee", "Shawano"),
    southwestern = c("Dane", "Green", "Rock", "Iowa", "Lafayette", "Grant", "Crawford", "Richland", "Sauk", "Columbia", "Juneau", "Vernon"),
    southeastern = c("Milwaukee", "Ozaukee", "Washington", "Waukesha", "Racine", "Kenosha", "Walworth", "Jefferson", "Dodge", "Sheboygan"),
    central = c("Wood", "Portage", "Marathon", "Adams", "Waushara", "Waupaca", "Outagamie", "Winnebago", "Fond du Lac", "Green Lake", "Marquette", "Clark", "Taylor")
  )
  alias_to_group <- c(
    statewide = "statewide",
    "state of wisconsin" = "statewide",
    wisconsin = "statewide",
    northwest = "northwestern",
    northwestern = "northwestern",
    "north west" = "northwestern",
    northeast = "northeastern",
    northeastern = "northeastern",
    "north east" = "northeastern",
    southwest = "southwestern",
    southwestern = "southwestern",
    "south west" = "southwestern",
    southeast = "southeastern",
    southeastern = "southeastern",
    "south east" = "southeastern",
    central = "central",
    "north central" = "central",
    "south central" = "southwestern"
  )
  out <- character(0)
  for (tok in tokens) {
    group <- alias_to_group[[tok]] %||% NA_character_
    if (!is.na(group)) {
      counties <- county_groups[[group]] %||% character(0)
      out <- c(out, as.character(wi_zctas$zipcode[wi_zctas$county_name %in% counties]))
    }
  }
  unique(out)
}


# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Combines all four extractors (zip / county / place / roadway /
# region alias) to translate the regions string into a unique ZIP set.
# How: cache lookup + put.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
resolve_511_region_zipcodes <- function(regions_text) {
  txt <- safe_string(regions_text)
  if (!nzchar(txt)) return(character(0))
  tokens <- unique(trimws(unlist(strsplit(gsub("[;|/]+", ",", tolower(txt)), ","), use.names = FALSE)))
  tokens <- tokens[nzchar(tokens)]
  unique(c(
    extract_zipcodes_from_text(txt),
    extract_county_zipcodes_from_text(txt),
    extract_place_zipcodes_from_text(txt),
    extract_roadway_zipcodes_from_text(txt),
    region_alias_zipcodes(tokens)
  ))
}


# Why: WI511 publishes prose alerts (no inherent geometry) so we score them
# generically and let downstream code resolve their geographies from text.
# What: returns a data.frame(alert_id, score, message, notes,
# high_importance, send_notification, regions, reason_text), or empty
# data.frame when no key/payload.
# How: walks the alerts feed, applies score_511_alert_risk, drops
# zero-score rows, caches.
# When: called by compute_511_alert_zip_signal.
# Impact: a missing key returns empty data and the alert layer goes dark
# without a visible error.
fetch_511_alerts_live <- function() {
  key <- "wi511-alerts-live"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  if (!has_wi511_key()) {
    out <- data.frame(alert_id = character(), score = numeric(), message = character(), notes = character(), high_importance = logical(), send_notification = logical(), regions = character(), reason_text = character(), stringsAsFactors = FALSE)
    cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }
  payload <- safely(
    http_json_query(WI511_ALERTS_URL, query = list(key = WI511_API_KEY, format = "json"))
  )
  items <- if (is.data.frame(payload)) split(payload, seq_len(nrow(payload))) else (payload %||% list())
  rows <- vector("list", 0)
  total_seen <- 0L
  dropped_low_risk <- 0L
  if (is.list(items) && length(items) > 0) {
    for (it in items) {
      total_seen <- total_seen + 1L
      message <- extract_named_character(it, c("Message", "message"), default = "")
      notes <- extract_named_character(it, c("Notes", "notes"), default = "")
      high_importance <- isTRUE(extract_named_value(it, c("HighImportance", "highImportance"), default = FALSE))
      send_notification <- isTRUE(extract_named_value(it, c("SendNotification", "sendNotification"), default = FALSE))
      alert_id <- extract_named_character(it, c("Id", "ID", "id"), default = NA_character_)
      regions_obj <- extract_named_value(it, c("Regions", "regions"), default = character(0))
      regions <- if (is.list(regions_obj)) paste(unlist(regions_obj, use.names = FALSE), collapse = ", ") else safe_string(regions_obj)
      score <- score_511_alert_risk(message, notes, high_importance = high_importance, send_notification = send_notification)
      if (!is.finite(score) || score < WI511_MIN_RISK_THRESHOLD) {
        dropped_low_risk <- dropped_low_risk + 1L
        next
      }
      rows[[length(rows) + 1L]] <- data.frame(
        alert_id = as.character(alert_id %||% paste0("511alert-", length(rows) + 1L)),
        score = score,
        message = safe_string(message),
        notes = safe_string(notes),
        high_importance = high_importance,
        send_notification = send_notification,
        regions = safe_string(regions),
        reason_text = sprintf("511WI alert: %s", ifelse(nzchar(message), message, "Traffic alert")),
        stringsAsFactors = FALSE
      )
    }
  }
  # Use base::message — the loop above shadows `message` with each alert body.
  base::message(sprintf("[FLOWS-DEBUG] 511 alerts: kept %d / %d (dropped %d below threshold %.2f).",
                        length(rows), total_seen, dropped_low_risk, WI511_MIN_RISK_THRESHOLD))
  out <- if (length(rows) == 0) data.frame(alert_id = character(), score = numeric(), message = character(), notes = character(), high_importance = logical(), send_notification = logical(), regions = character(), reason_text = character(), stringsAsFactors = FALSE) else dplyr::bind_rows(rows)
  cache_put("derived", key, out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}


# Why: WI511 alerts need a per-ZIP score plus reason-text join even though
# the alerts have no native geometry.
# What: returns list(scores, reasons) keyed by zipcode; reasons hold the
# best matching alert's reason_text.
# How: per alert, runs all five extractors (zip/county/place/roadway/region)
# on the message+notes+regions blob; falls back to statewide at half score
# when high_importance and nothing matched; takes per-zip max.
# When: called by the WI511 transport pipeline.
# Impact: the high-importance fallback prevents alerts with sparse text
# from being silenced; can over-broadcast if mis-tagged.
compute_511_alert_zip_signal <- function(horizon_key = "live") {
  cache_name <- paste0("wi511-alert-zip-signal-", horizon_key)
  cached <- cache_get("derived", cache_name)
  if (!is.null(cached)) return(cached)
  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_reasons <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  alerts <- fetch_511_alerts_live()
  if (nrow(alerts) == 0) {
    out <- list(scores = out_scores, reasons = out_reasons)
    cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
    return(out)
  }
  for (i in seq_len(nrow(alerts))) {
    text_blob <- paste(alerts$message[i], alerts$notes[i], alerts$regions[i], collapse = " | ")
    zipcodes <- unique(c(
      extract_zipcodes_from_text(text_blob),
      extract_county_zipcodes_from_text(text_blob),
      extract_place_zipcodes_from_text(text_blob),
      extract_roadway_zipcodes_from_text(text_blob),
      resolve_511_region_zipcodes(alerts$regions[i])
    ))
    score <- alerts$score[i]
    if (!identical(horizon_key, "live")) {
      score <- apply_live_decay(score, horizon_key, half_life_hours = 10)
    }
    if (!length(zipcodes) && isTRUE(alerts$high_importance[i])) {
      zipcodes <- wi_zctas$zipcode
      score <- max(score * 0.45, 0.18)
    }
    if (!length(zipcodes)) next
    zipcodes <- unique(as.character(stats::na.omit(zipcodes)))
    idx <- match(zipcodes, wi_zctas$zipcode)
    idx <- idx[is.finite(idx)]
    if (!length(idx)) next
    better <- score > out_scores[idx]
    out_scores[idx[better]] <- score
    out_reasons[idx[better]] <- alerts$reason_text[i]
  }
  out <- list(scores = out_scores, reasons = out_reasons)
  cache_put("derived", cache_name, out, ttl_seconds = if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS)
  out
}

