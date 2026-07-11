# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/radnet_nrc.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Decodes the basic HTML entities and CDATA wrappers in NRC RSS
# payloads without pulling in a full XML/HTML parser.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
decode_html_entities_simple <- function(x) {
  x <- as.character(x %||% "")
  x <- gsub("<!\\[CDATA\\[", "", x, perl = TRUE)
  x <- gsub("\\]\\]>", "", x, perl = TRUE)
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&amp;", "&", x, fixed = TRUE)
  x <- gsub("&quot;", '"', x, fixed = TRUE)
  x <- gsub("&#39;", "'", x, fixed = TRUE)
  x
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Strips XML/HTML tags and collapses whitespace - decodes entities
# first so resulting plain text is human readable.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
strip_xml_tags_simple <- function(x) {
  x <- decode_html_entities_simple(x)
  x <- gsub("<[^>]+>", " ", x, perl = TRUE)
  x <- gsub("\\s+", " ", x, perl = TRUE)
  trimws(x)
}

# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the inner text of the first <tag>...</tag> match
# (case-insensitive), stripped of any nested tags - lightweight regex
# extractor.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_xml_tag_value_simple <- function(xml_text, tag_name) {
  pattern <- sprintf("<%s(?:[^>]*)>(.*?)</%s>", tag_name, tag_name)
  matches <- regmatches(xml_text, gregexpr(pattern, xml_text, perl = TRUE, ignore.case = TRUE))[[1]]
  if (length(matches) == 0) return(NA_character_)
  value <- matches[[1]]
  value <- sub(sprintf("^<%s(?:[^>]*)>", tag_name), "", value, perl = TRUE, ignore.case = TRUE)
  value <- sub(sprintf("</%s>$", tag_name), "", value, perl = TRUE, ignore.case = TRUE)
  strip_xml_tags_simple(value)
}

# Why: avoid a heavy XML dependency for a feed we already trust to be a
# simple RSS list of NRC events.
# What: returns a data.frame(title, description, link, pub_date) - empty
# data.frame if no <item> elements are present.
# How: regex-extracts every <item>...</item>, then runs
# extract_xml_tag_value_simple per child tag and binds the rows.
# When: called by fetch_nrc_radiation_signal each TTL cycle.
# Impact: a malformed feed returns zero rows and the radiation signal
# silently goes to 0; wrong tag casing in upstream feeds breaks parsing.
parse_simple_rss_items <- function(xml_text) {
  xml_text <- as.character(xml_text %||% "")
  item_matches <- regmatches(xml_text, gregexpr("<item\\b.*?>.*?</item>", xml_text, perl = TRUE, ignore.case = TRUE))[[1]]
  if (length(item_matches) == 0) {
    return(data.frame(title = character(), description = character(), link = character(), pub_date = character(), stringsAsFactors = FALSE))
  }
  rows <- lapply(item_matches, function(item) {
    data.frame(
      title = extract_xml_tag_value_simple(item, "title"),
      description = extract_xml_tag_value_simple(item, "description"),
      link = extract_xml_tag_value_simple(item, "link"),
      pub_date = extract_xml_tag_value_simple(item, "pubDate"),
      stringsAsFactors = FALSE
    )
  })
  flows_bind_rows(rows)
}

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Lowercases and replaces non-alphanumerics with single spaces - used
# to fuzzy-match RadNet station place names.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_place_name_simple <- function(x) {
  x <- tolower(as.character(x %||% ""))
  x <- gsub("[^a-z0-9]+", " ", x, perl = TRUE)
  trimws(x)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Finds the sf row in load_places() whose normalised name matches
# place_name, returning a CRS-4326 point on its surface (NULL if no match).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
lookup_place_point_by_name <- function(place_name) {
  places <- load_places()
  if (is.null(places) || nrow(places) == 0) return(NULL)
  norm_target <- normalize_location_query_text(normalize_place_name_simple(place_name))
  place_norm <- normalize_location_query_text(normalize_place_name_simple(places$NAME))
  hit <- which(place_norm == norm_target)
  if (length(hit) == 0) return(NULL)
  pts <- point_on_surface_lonlat(places[hit[1], , drop = FALSE])
  if (nrow(pts) == 0) return(NULL)
  pts
}

# Why: RadNet CSVs use various date/time column shapes; we need a single
# UTC POSIXct vector to sort observations chronologically.
# What: returns a length-nrow(dat) POSIXct vector (NA where unparseable).
# How: scans for date/time columns, tries a list of standard formats; if
# two columns are present, concatenates them before parsing.
# When: called inside score_radnet_monitor_data before time-ordering.
# Impact: bad timestamps mean the "latest vs baseline" excursion compares
# random rows, producing garbage scores.
parse_radnet_timestamp_vector <- function(dat) {
  nms <- names(dat)
  if (is.null(nms) || length(nms) == 0 || nrow(dat) == 0) return(rep(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"), nrow(dat)))
  date_idx <- grep("date|time|timestamp|utc|gmt", nms, ignore.case = TRUE)
  if (length(date_idx) == 0) return(rep(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"), nrow(dat)))
  parse_one <- function(x) {
    x <- trimws(safe_string(x))
    if (!nzchar(x)) return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
    fmts <- c(
      "%Y-%m-%d %H:%M:%S",
      "%Y-%m-%d %H:%M",
      "%m/%d/%Y %H:%M:%S",
      "%m/%d/%Y %H:%M",
      "%Y/%m/%d %H:%M:%S",
      "%Y/%m/%d %H:%M"
    )
    for (fmt in fmts) {
      parsed <- suppressWarnings(as.POSIXct(x, format = fmt, tz = "UTC"))
      if (!is.na(parsed)) return(parsed)
    }
    suppressWarnings(as.POSIXct(x, tz = "UTC"))
  }
  if (length(date_idx) == 1) {
    return(vapply(dat[[date_idx[1]]], parse_one, as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")))
  }
  vals <- apply(dat[, date_idx[1:2], drop = FALSE], 1, function(r) paste(r, collapse = " "))
  vapply(vals, parse_one, as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
}

# Why: detect anomalies in RadNet station readings without false positives
# from natural variability.
# What: returns list(score, label) - score is the highest 0..1 anomaly
# across promising columns; label is currently always NA.
# How: parses timestamps, picks numeric (or numeric-like) columns excluding
# obvious metadata fields, prefers exposure/gamma/dose/rate columns, and
# scores each by IQR-based excursion AND latest/baseline ratio - max wins.
# When: called per RadNet station in fetch_radnet_wi_scores.
# Impact: changing the IQR floor or piecewise thresholds shifts the false-
# positive rate on baseline-noisy stations.
score_radnet_monitor_data <- function(dat) {
  if (is.null(dat) || !is.data.frame(dat) || nrow(dat) == 0) return(list(score = 0, label = NA_character_))
  times <- parse_radnet_timestamp_vector(dat)
  ord <- order(times)
  if (length(ord) == nrow(dat) && any(!is.na(times))) dat <- dat[ord, , drop = FALSE]
  nms <- names(dat)
  numeric_candidates <- nms[vapply(dat, function(col) is.numeric(col) || is.integer(col), logical(1))]
  if (length(numeric_candidates) == 0) {
    numeric_candidates <- nms[vapply(dat, function(col) {
      vals <- safe_numeric(as.character(col))
      sum(is.finite(vals)) >= max(12, floor(length(vals) * 0.5))
    }, logical(1))]
    for (nm in numeric_candidates) dat[[nm]] <- safe_numeric(as.character(dat[[nm]]))
  }
  numeric_candidates <- numeric_candidates[!grepl("year|month|day|hour|min|sec|julian|time zone|timezone|channel.*(low|high)|range", numeric_candidates, ignore.case = TRUE)]
  if (length(numeric_candidates) == 0) return(list(score = 0, label = NA_character_))

  preferred <- numeric_candidates[grepl("exposure|gamma|gross|count|rate|dose", numeric_candidates, ignore.case = TRUE)]
  if (length(preferred) > 0) numeric_candidates <- unique(c(preferred, numeric_candidates))

  col_scores <- vapply(numeric_candidates, function(nm) {
    vals <- safe_numeric(dat[[nm]])
    vals <- vals[is.finite(vals)]
    if (length(vals) < 24) return(0)
    baseline_cutoff <- max(12, length(vals) - min(12, length(vals) - 1))
    baseline_vals <- vals[seq_len(baseline_cutoff)]
    latest <- tail(vals, 1)
    baseline <- stats::median(baseline_vals, na.rm = TRUE)
    spread <- stats::IQR(baseline_vals, na.rm = TRUE)
    spread <- max(spread, abs(baseline) * 0.08, 1e-6)
    excursion <- (latest - baseline) / spread
    ratio <- latest / max(abs(baseline), 1e-6)
    max(piecewise_score(excursion, 1.0, 3.0, 6.0), piecewise_score(ratio - 1, 0.10, 0.40, 1.00), na.rm = TRUE)
  }, numeric(1))

  if (!any(is.finite(col_scores) & col_scores > 0)) return(list(score = 0, label = NA_character_))
  list(score = pmin(1, max(col_scores, na.rm = TRUE)), label = NA_character_)
}

# Why: convert EPA RadNet station anomaly scores into per-ZCTA radiation
# scores by snapping each ZIP centroid to its nearest scored station.
# What: returns list(scores, labels) keyed by zipcode, cached for 6 hours.
# How: iterates RADNET_WI_MONITOR_SPECS, fetches CSV for current/prior
# year, parses with score_radnet_monitor_data, locates the station via
# lookup_place_point_by_name, then nearest-station-broadcast over wi_zctas.
# When: called by the radiation hazard pipeline.
# Impact: a missing station (no CSV) is skipped; geographic broadcast is
# coarse, so a single anomalous station can paint a large ring of ZIPs.
fetch_radnet_wi_scores <- function() {
  key <- "radnet-wi-scores"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)

  year_now <- as.integer(format(Sys.Date(), "%Y"))
  fetch_one_station <- function(spec) {
    txt <- NULL
    for (yr in unique(c(year_now, year_now - 1L))) {
      url <- sprintf("https://radnet.epa.gov/cdx-radnet-rest/api/rest/csv/%s/fixed/WI/%s", yr, spec$slug)
      txt <- safely(http_text(url, user_agent = NOAA_USER_AGENT))
      if (!is.null(txt) && nzchar(trimws(txt))) break
    }
    if (is.null(txt) || !nzchar(trimws(txt))) return(NULL)
    lines <- readLines(textConnection(txt), warn = FALSE)
    header_idx <- which(grepl(",", lines) & grepl("date|time|gamma|exposure|rate", lines, ignore.case = TRUE))
    if (length(header_idx) == 0) return(NULL)
    csv_txt <- paste(lines[header_idx[1]:length(lines)], collapse = "\n")
    dat <- safely(utils::read.csv(text = csv_txt, stringsAsFactors = FALSE, check.names = TRUE))
    if (is.null(dat) || nrow(dat) == 0) return(NULL)
    scored <- score_radnet_monitor_data(dat)
    place_pt <- lookup_place_point_by_name(spec$place_name)
    if (is.null(place_pt) || nrow(place_pt) == 0) return(NULL)
    coords <- sf::st_coordinates(place_pt)
    data.frame(
      place_name = spec$place_name,
      lon = coords[1, 1],
      lat = coords[1, 2],
      radnet_score = scored$score,
      radnet_reason = if (isTRUE(scored$score > 0)) sprintf("EPA RadNet anomaly elevated near %s.", spec$place_name) else NA_character_,
      stringsAsFactors = FALSE
    )
  }
  # Parallelise across the 4 WI RadNet stations: each is an independent EPA
  # CDX HTTP fetch + CSV parse, dominated by network latency. mclapply forks
  # cleanly on macOS / Linux; Windows transparently falls through to lapply.
  use_parallel <- .Platform$OS.type != "windows"
  results <- if (use_parallel) {
    parallel::mclapply(RADNET_WI_MONITOR_SPECS, fetch_one_station,
                       mc.cores = max(1L, min(length(RADNET_WI_MONITOR_SPECS), 4L)),
                       mc.preschedule = FALSE)
  } else {
    lapply(RADNET_WI_MONITOR_SPECS, fetch_one_station)
  }
  rows <- Filter(Negate(is.null), results)

  out_scores <- stats::setNames(rep(0, nrow(wi_zctas)), wi_zctas$zipcode)
  out_labels <- stats::setNames(rep(NA_character_, nrow(wi_zctas)), wi_zctas$zipcode)
  if (length(rows) == 0) {
    out <- list(scores = out_scores, labels = out_labels)
    cache_put("derived", key, out, ttl_seconds = 6 * 3600)
    return(out)
  }

  monitor_df <- flows_bind_rows(rows)
  monitor_sf <- sf::st_as_sf(monitor_df, coords = c("lon", "lat"), crs = 4326)
  nearest_idx <- suppressWarnings(sf::st_nearest_feature(wi_zip_points, monitor_sf))
  out_scores <- monitor_sf$radnet_score[nearest_idx]
  out_labels <- monitor_sf$radnet_reason[nearest_idx]
  names(out_scores) <- wi_zctas$zipcode
  names(out_labels) <- wi_zctas$zipcode
  out_scores[!is.finite(out_scores)] <- 0
  out <- list(scores = out_scores, labels = out_labels)
  cache_put("derived", key, out, ttl_seconds = 6 * 3600)
  out
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps NRC event report text to a 0..1 severity score by keyword
# (general emergency = 1.00, alert = 0.80, unusual event = 0.55, etc.).
# How: regex match + guarded numeric coercion.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_nrc_event_text <- function(text) {
  text <- tolower(safe_string(text))
  if (!nzchar(text)) return(0)
  levels <- c(
    if (grepl("general emergency", text, fixed = TRUE)) 1.00 else 0,
    if (grepl("site area emergency", text, fixed = TRUE)) 0.95 else 0,
    if (grepl("\\balert\\b", text, perl = TRUE)) 0.80 else 0,
    if (grepl("unusual event", text, fixed = TRUE)) 0.55 else 0,
    if (grepl("radiological|radioactive|contamination|release", text, perl = TRUE)) 0.75 else 0,
    if (grepl("tritium|leak|leakage|fuel damage", text, perl = TRUE)) 0.55 else 0
  )
  max(levels, na.rm = TRUE)
}

# Why: callers need a boolean predicate that's NA-safe and consistent
# across every site that needs the same classification.
# What: Predicate: TRUE if title+description text mentions Wisconsin, "wi",
# or one of the named WI nuclear sites (Point Beach, Kewaunee, etc.).
# How: regex match + cache lookup + put + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
is_wisconsin_nrc_event <- function(title, description) {
  text <- tolower(paste(title %||% "", description %||% ""))
  grepl("\\bwisconsin\\b|\\bwi\\b|point beach|kewaunee|la crosse|madison|milwaukee|shawano", text, perl = TRUE)
}

# Why: the upstream payload arrives in an unstructured shape that the rest
# of the pipeline can't consume directly.
# What: Parses an NRC RSS pubDate ("Mon, 02 Jan 2024 13:45:00 +0000") to
# UTC POSIXct, falling back to a generic POSIXct cast.
# How: cache lookup + put + guarded numeric coercion.
# When: called immediately after the upstream HTTP fetch resolves, before
# the result is handed to the scorer or shape converter.
# Impact: upstream schema drift is the main failure mode; the function
# tries multiple field-name spellings to absorb minor changes.
parse_nrc_pubdate <- function(x) {
  x <- trimws(safe_string(x))
  if (!nzchar(x)) return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  parsed <- suppressWarnings(as.POSIXct(x, format = "%a, %d %b %Y %H:%M:%S %z", tz = "UTC"))
  if (!is.na(parsed)) return(parsed)
  suppressWarnings(as.POSIXct(x, tz = "UTC"))
}

# Why: surface a single statewide "is there an active NRC nuclear event near
# Wisconsin?" signal for the radiation layer.
# What: returns list(score, label, url) summarising the worst recent WI-
# specific event from the NRC daily event RSS, cached for 30 minutes.
# How: fetches the RSS, parses items, filters to recent (< NRC_EVENT_LOOKBACK_DAYS)
# WI-related events with non-zero score, picks the highest-score most-recent
# one and returns its title/link.
# When: called by the radiation pipeline once per cycle.
# Impact: keyword-based filtering can miss obliquely worded events;
# label/url are surfaced verbatim into the popup so escaping happens later.
fetch_nrc_radiation_signal <- function() {
  key <- "nrc-radiation-signal"
  cached <- cache_get("derived", key)
  if (!is.null(cached)) return(cached)
  txt <- safely(http_text(NRC_EVENT_RSS_URL, user_agent = NOAA_USER_AGENT))
  if (is.null(txt) || !nzchar(trimws(txt))) {
    out <- list(score = 0, label = NA_character_, url = NA_character_)
    cache_put("derived", key, out, ttl_seconds = 1800)
    return(out)
  }
  rss <- parse_simple_rss_items(txt)
  if (nrow(rss) == 0) {
    out <- list(score = 0, label = NA_character_, url = NA_character_)
    cache_put("derived", key, out, ttl_seconds = 1800)
    return(out)
  }
  rss$event_time <- vapply(rss$pub_date, parse_nrc_pubdate, as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  rss$recent <- is.na(rss$event_time) | rss$event_time >= (Sys.time() - NRC_EVENT_LOOKBACK_DAYS * 86400)
  rss$wi_hit <- mapply(is_wisconsin_nrc_event, rss$title, rss$description)
  rss$score <- mapply(function(tt, dd) score_nrc_event_text(paste(tt, dd)), rss$title, rss$description)
  rss <- rss[rss$recent & rss$wi_hit & is.finite(rss$score) & rss$score > 0, , drop = FALSE]
  if (nrow(rss) == 0) {
    out <- list(score = 0, label = NA_character_, url = NA_character_)
    cache_put("derived", key, out, ttl_seconds = 1800)
    return(out)
  }
  order_key <- order(-rss$score, ifelse(is.na(rss$event_time), 0, as.numeric(rss$event_time)))
  best <- rss[order_key[1], , drop = FALSE]
  out <- list(
    score = pmin(1, best$score[[1]]),
    label = paste0("NRC Daily Event Report: ", best$title[[1]]),
    url = best$link[[1]] %||% NA_character_
  )
  cache_put("derived", key, out, ttl_seconds = 1800)
  out
}
