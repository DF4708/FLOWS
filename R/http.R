# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/http.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: every external feed in this app needs the same robust GET behaviour
# (NOAA-friendly UA, retries, geo+json Accept) so we centralise it once here.
# What: returns the response body as a character string, or throws on failure.
# How: builds an httr2 request with user agent, JSON-friendly Accept header,
# clamped timeout, and bounded retry policy, then performs and reads body.
# When: the lowest-level wrapper used by http_json, http_json_simple, and
# any other module needing raw text from a URL.
# Impact: changing defaults here ripples to every feed - a too-short timeout
# starves alerts/forecasts; missing UA can get the app blocked by NOAA.
http_text <- function(url, user_agent = NOAA_USER_AGENT, timeout_seconds = DEFAULT_HTTP_TIMEOUT_SECONDS, max_tries = DEFAULT_HTTP_MAX_TRIES) {
  req <- httr2::request(url)
  req <- httr2::req_user_agent(req, user_agent)
  req <- httr2::req_headers(req, Accept = "application/geo+json, application/ld+json, application/json, */*")
  req <- httr2::req_timeout(req, max(5, safe_numeric(timeout_seconds %||% DEFAULT_HTTP_TIMEOUT_SECONDS)))
  req <- httr2::req_retry(req, max_tries = max(1, suppressWarnings(as.integer(max_tries %||% DEFAULT_HTTP_MAX_TRIES))))
  resp <- httr2::req_perform(req)
  httr2::resp_body_string(resp)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Fetches URL with http_text and parses as JSON with simplifyVector =
# FALSE so nested structures stay as nested lists.
# How: sf geometry op + HTTP JSON fetch + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
http_json <- function(url, user_agent = NOAA_USER_AGENT, timeout_seconds = DEFAULT_HTTP_TIMEOUT_SECONDS, max_tries = DEFAULT_HTTP_MAX_TRIES) {
  txt <- http_text(url, user_agent = user_agent, timeout_seconds = timeout_seconds, max_tries = max_tries)
  jsonlite::fromJSON(txt, simplifyVector = FALSE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Fetches URL and parses JSON with default simplifyVector behaviour,
# returning NULL on parse error.
# How: regex match + sf geometry op + HTTP JSON fetch + guarded numeric
# coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
http_json_simple <- function(url, user_agent = NOAA_USER_AGENT, timeout_seconds = DEFAULT_HTTP_TIMEOUT_SECONDS, max_tries = DEFAULT_HTTP_MAX_TRIES) {
  txt <- http_text(url, user_agent = user_agent, timeout_seconds = timeout_seconds, max_tries = max_tries)
  safely(jsonlite::fromJSON(txt))
}

# Why: large binary feeds (shapefiles, KMZ, geodatabases) are too big to keep
# in memory and need an on-disk path for sf::st_read or unzip.
# What: returns the path to a freshly-downloaded tempfile (with optional file
# extension); errors propagate from httr2 on persistent failure.
# How: same retry/UA pattern as http_text but with a longer download timeout
# and req_perform writing directly to a tempfile.
# When: used by reference-data loaders (zones, ZCTAs, road tiles, RadNet KMZ)
# before unzipping or sf-reading the file.
# Impact: failure aborts the loader which then propagates an empty fallback;
# leaving stale temp files is acceptable since they live in tempdir().
download_to_tempfile <- function(url, fileext = "", user_agent = NOAA_USER_AGENT, timeout_seconds = DEFAULT_DOWNLOAD_TIMEOUT_SECONDS, max_tries = DEFAULT_HTTP_MAX_TRIES) {
  tmp_file <- tempfile(fileext = fileext)
  req <- httr2::request(url)
  req <- httr2::req_user_agent(req, user_agent)
  req <- httr2::req_headers(req, Accept = "*/*")
  req <- httr2::req_timeout(req, max(10, safe_numeric(timeout_seconds %||% DEFAULT_DOWNLOAD_TIMEOUT_SECONDS)))
  req <- httr2::req_retry(req, max_tries = max(1, suppressWarnings(as.integer(max_tries %||% DEFAULT_HTTP_MAX_TRIES))))
  httr2::req_perform(req, path = tmp_file)
  tmp_file
}

# Why: callers need a boolean predicate that's NA-safe and consistent
# across every site that needs the same classification.
# What: Predicate: TRUE for harmless sf::st_read warnings (currently the
# "invalid winding order" notice).
# How: regex match + sf geometry op + HTTP JSON fetch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
is_benign_sf_read_warning <- function(message) {
  grepl("invalid winding order", safe_string(message), ignore.case = TRUE)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Wraps sf::st_read to muffle warnings flagged as benign by
# is_benign_sf_read_warning.
# How: sf geometry op + HTTP JSON fetch + row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
read_sf_quietly <- function(dsn, quiet = TRUE, ...) {
  withCallingHandlers(
    sf::st_read(dsn, quiet = quiet, ...),
    warning = function(w) {
      if (is_benign_sf_read_warning(conditionMessage(w))) {
        invokeRestart("muffleWarning")
      }
    }
  )
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE if WI511_API_KEY is set to a non-empty string,
# gating optional WI511 feeds.
# How: regex match + HTTP JSON fetch + row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
has_wi511_key <- function() {
  nzchar(trimws(WI511_API_KEY %||% ""))
}

# Why: many endpoints expect URL-encoded query strings; we want one helper that
# also handles array-valued params and keeps NULL/NA-only entries out.
# What: returns the URL with an appended query string (or the unchanged URL
# if no query parameters survived filtering).
# How: drops NULL entries, expands list values into repeated key=value pairs,
# URL-encodes both name and value, and appends with the right separator.
# When: called by http_json_query and other callers that build endpoint URLs
# from a list of optional parameters.
# Impact: a URL-encoding bug here would break any feed that uses spaces or
# special characters in identifiers, alert IDs, or station IDs.
build_url_with_query <- function(url, query = list()) {
  if (length(query) == 0) return(url)
  query <- query[!vapply(query, is.null, logical(1))]
  if (length(query) == 0) return(url)
  parts <- unlist(lapply(names(query), function(nm) {
    val <- query[[nm]]
    if (length(val) == 0 || all(is.na(val))) return(character(0))
    vapply(as.character(val), function(x) {
      paste0(utils::URLencode(nm, reserved = TRUE), "=", utils::URLencode(x, reserved = TRUE))
    }, character(1))
  }), use.names = FALSE)
  if (length(parts) == 0) return(url)
  paste0(url, if (grepl("?", url, fixed = TRUE)) "&" else "?", paste(parts, collapse = "&"))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Convenience: build_url_with_query then http_json - lets callers
# pass query parameters as a list.
# How: HTTP JSON fetch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
http_json_query <- function(url, query = list(), user_agent = NOAA_USER_AGENT, timeout_seconds = DEFAULT_HTTP_TIMEOUT_SECONDS, max_tries = DEFAULT_HTTP_MAX_TRIES) {
  http_json(build_url_with_query(url, query), user_agent = user_agent, timeout_seconds = timeout_seconds, max_tries = max_tries)
}

# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the first non-NULL value in obj across the given candidate
# names, otherwise default.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_named_value <- function(obj, names, default = NULL) {
  for (nm in names) {
    if (!is.null(obj[[nm]])) return(obj[[nm]])
  }
  default
}

# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the first non-empty character value found across candidate
# names in obj, else default.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_named_character <- function(obj, names, default = NA_character_) {
  val <- extract_named_value(obj, names, default = default)
  if (is.null(val) || length(val) == 0) return(default)
  out <- as.character(val[[1]] %||% val[1])
  if (!nzchar(trimws(out))) default else out
}

# Why: upstream payload structures vary; this helper centralises the
# field-name search so callers don't repeat the OR-chain in every spot.
# What: Returns the first finite numeric value found across candidate names
# in obj, else default.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
extract_named_numeric_any <- function(obj, names, default = NA_real_) {
  val <- extract_named_value(obj, names, default = default)
  if (is.null(val) || length(val) == 0) return(default)
  out <- safe_numeric(val[[1]] %||% val[1])
  if (is.finite(out)) out else default
}

# Why: the user-facing display needs a consistent rendering of this value
# across popups / summaries / legends.
# What: Formats a Unix timestamp x as "YYYY-mm-dd HH:MM UTC", or
# NA_character_ when x is non-finite.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: any change to the rendering shows up directly in popups / legends
# / summaries; keep callers' assumptions about output shape (e.g., "%s%%")
# stable.
format_unix_time_or_na <- function(x) {
  val <- safe_numeric(x)
  if (!is.finite(val)) return(NA_character_)
  format(as.POSIXct(val, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d %H:%M UTC", tz = "UTC")
}
