# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/util.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Null-coalescing operator: returns x unless it is NULL or empty, in which case returns y.
`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) y else x
}

# Why: the leaflet ZIP polygon layer is expensive to redraw, so the server only
# re-renders when the underlying risk/alert data actually changed.
# What: returns a character vector with one pipe-delimited fingerprint per ZIP
# row capturing all attributes that drive visual output.
# How: paste together zipcode, normalized/fill risk (rounded), label, RGBA, and
# alert/popup fields so a row-wise compare detects any cell change.
# When: called by the server before deciding to invalidate the cached zip layer
# and again after the new data is materialised, to compare signatures.
# Impact: if a relevant column is omitted here, the map will not refresh when
# that column changes; if too many columns are included, redraws thrash.
zip_render_signature_vector <- function(zips, include_popup = !isTRUE(LAZY_ZIP_POPUPS_ENABLED)) {
  popup_component <- if (isTRUE(include_popup) && "popup_label" %in% names(zips)) {
    ifelse(is.na(zips$popup_label), "", zips$popup_label)
  } else {
    rep("", nrow(zips))
  }
  paste(
    zips$zipcode,
    round(zips$normalized_risk_score, 6),
    round(zips$fill_risk_score, 6),
    zips$display_risk_label,
    zips$risk_fill_rgba,
    ifelse(is.na(zips$alert_event), "", zips$alert_event),
    ifelse(is.na(zips$alert_url), "", zips$alert_url),
    ifelse(is.na(zips$alert_event_list), "", zips$alert_event_list),
    ifelse(is.na(zips$alert_url_list), "", zips$alert_url_list),
    popup_component,
    sep = "|"
  )
}

# Why: with LAZY_ZIP_POPUPS_ENABLED, popup HTML is not bound to every polygon up
# front, so we must build it on-demand from the clicked feature.
# What: returns a list(lng, lat, html) used by the client popup, or NULL when
# the feature has no popup_label or lazy popups are disabled.
# How: looks up the clicked id in polys$zipcode, pulls popup_label, and pairs it
# with the click's lng/lat coordinates.
# When: invoked from a Leaflet shape_click observer in server.R when the user
# clicks a ZIP polygon and lazy popups are turned on.
# Impact: a NULL/empty result silently suppresses the popup; mismatched id
# normalisation here causes "no popup on click" bugs.
zip_popup_payload_from_click <- function(click = NULL, polys = NULL) {
  if (!isTRUE(LAZY_ZIP_POPUPS_ENABLED)) return(NULL)
  if (is.null(click) || is.null(polys) || !inherits(polys, "sf") || nrow(polys) == 0) return(NULL)
  click_id <- as.character(click$id %||% "")
  if (!nzchar(click_id)) return(NULL)
  hit <- polys[as.character(polys$zipcode %||% "") %in% click_id, , drop = FALSE]
  if (nrow(hit) == 0) return(NULL)
  popup_html <- as.character(hit$popup_label[[1]] %||% "")
  if (!nzchar(popup_html)) return(NULL)
  list(
    lng = suppressWarnings(as.numeric(click$lng %||% NA_real_)),
    lat = suppressWarnings(as.numeric(click$lat %||% NA_real_)),
    html = popup_html
  )
}

# Escapes regex metacharacters in x so it can be embedded literally in a regex pattern.
regex_escape <- function(x) {
  gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", as.character(x %||% ""), perl = TRUE)
}

# Lowercases x, strips non-alphanumerics, and collapses whitespace for tolerant string matching.
normalize_match_text <- function(x) {
  txt <- tolower(as.character(x %||% ""))
  txt <- gsub("[^a-z0-9 ]", " ", txt, perl = TRUE)
  trimws(gsub("\\s+", " ", txt, perl = TRUE))
}

# Why: `suppressWarnings(as.numeric(x))` is the most repeated coercion pattern
# in this codebase (~160 occurrences). Centralizing it eliminates ~80 LOC and
# makes the intent obvious at call sites.
# What: returns x coerced to numeric without emitting NAs-introduced warnings.
# How: thin wrapper around suppressWarnings(as.numeric(...)).
# When: anywhere a tolerant numeric coerce is wanted (parser results, JSON
# fields, user input).
# Impact: identical to suppressWarnings(as.numeric(x)) - safe drop-in.
safe_numeric <- function(x) suppressWarnings(as.numeric(x))

# Why: `as.character(x %||% "")` shows up in dozens of defensive guards. One
# line of intent beats one line of defensive paste.
# What: returns x coerced to character, with NULL/NA mapped to "".
# How: %||% selects "" for NULL, then as.character coerces.
# When: when null-or-empty-string semantics is desired and the value will
# be passed to something that expects a string.
# Impact: same behaviour as the inline pattern.
safe_string <- function(x) as.character(x %||% "")

# Why: `nzchar(trimws(as.character(x %||% "")))` is the standard "do we have
# a non-blank string?" guard.
# What: returns TRUE iff x is a non-blank scalar/vector (per element if
# vectorised input). Length-0 input returns FALSE.
# How: trims whitespace and tests with nzchar.
# When: alert text, popup labels, anywhere user-facing strings are emitted.
# Impact: drop-in for the existing pattern.
is_nontrivial_string <- function(x) {
  s <- trimws(as.character(x %||% ""))
  if (length(s) == 0L) FALSE else nzchar(s)
}

# Why: `tryCatch(expr, error = function(e) NULL)` is repeated ~30 times to
# turn errors into a NULL fallback.
# What: returns expr's value, or NULL if any error is raised.
# How: tryCatch with the standard error handler.
# When: best for I/O / parsers where a NULL caller-side fallback is the
# semantics you want.
# Impact: drop-in for the lambda pattern; does NOT log the error (callers
# wanting visibility should still write tryCatch with their own handler).
safely <- function(expr) tryCatch(expr, error = function(e) NULL)
