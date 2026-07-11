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

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Escapes regex metacharacters in x so it can be embedded literally
# in a regex pattern.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
regex_escape <- function(x) {
  gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", as.character(x %||% ""), perl = TRUE)
}

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Lowercases x, strips non-alphanumerics, and collapses whitespace
# for tolerant string matching.
# How: guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
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
  s <- as.character(x %||% "")
  if (length(s) == 0L) return(FALSE)
  # Anchor on `!is.na(s)` BEFORE nzchar — depending on locale/R build,
  # `nzchar(NA_character_)` can return TRUE rather than NA, which would
  # leak NAs through callers that use this in a boolean mask (e.g.
  # `mask <- dominant_names == key & is_nontrivial_string(src)`). NA
  # in the mask causes `vec[mask] <- replacement` to clobber the
  # corresponding row with NA — that was the source of "Driving
  # hazard: NA" popups on ZIPs whose dominant component lacked a
  # per-zip reason override.
  out <- rep(FALSE, length(s))
  ok <- !is.na(s)
  if (any(ok)) {
    out[ok] <- nzchar(trimws(s[ok]))
  }
  out
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

# Why: `dplyr::bind_rows` was the ONLY use of dplyr in FLOWS (16 call sites),
# and dplyr drags in a large dependency tree (rlang, vctrs, tibble, cli,
# pillar, glue, lifecycle). Owning this one primitive lets us drop the whole
# tree — fewer moving parts, faster load, no version churn. (Dependency-
# reduction SOP: replace convenience deps with a verified in-house tool; keep
# load-bearing ones like sf/httr2/shiny.)
# What: row-binds data.frames into one, mirroring bind_rows for the shapes
# FLOWS produces. Matches bind_rows' `...` signature: accepts EITHER a single
# list of data.frames (spliced) OR multiple data.frame arguments. Tolerates
# NULL / zero-column / zero-row elements, unions columns in first-appearance
# order, NA-fills missing columns, and concatenates rows in order. Returns a
# base data.frame (callers consume it directly or via sf::st_sf, both of which
# accept a plain data.frame identically to a tibble).
# How: normalise `...` to a list (single list arg is spliced, like bind_rows),
# then fast path when every element shares the same column vector
# (do.call(rbind)); general path adds missing columns as NA, reorders to the
# union, then rbinds. Row names are reset to match bind_rows' 1..n.
# When: anywhere the codebase previously called dplyr::bind_rows(...) — both
# the list form bind_rows(rows) and the multi-arg form bind_rows(a, b, c).
# Impact: proven byte-identical (as.data.frame-normalised) to dplyr::bind_rows
# across FLOWS' input shapes in tests/jobs/dep_reduction_equiv.R — re-run that
# gate if you extend this to new input patterns (e.g. factor columns).
flows_bind_rows <- function(...) {
  args <- list(...)
  # bind_rows(...) semantics: a single list-but-not-data.frame arg is spliced;
  # otherwise the args themselves are the frames to bind.
  dfs <- if (length(args) == 1L && is.list(args[[1L]]) && !is.data.frame(args[[1L]])) {
    args[[1L]]
  } else {
    args
  }
  if (length(dfs) == 0L) return(data.frame())
  dfs <- Filter(function(d) is.data.frame(d) && ncol(d) > 0L, dfs)
  if (length(dfs) == 0L) return(data.frame())
  cols <- unique(unlist(lapply(dfs, names), use.names = FALSE))
  same <- all(vapply(dfs, function(d) identical(names(d), cols), logical(1)))
  if (!same) {
    dfs <- lapply(dfs, function(d) {
      miss <- setdiff(cols, names(d))
      # rep(NA, nrow(d)), not bare NA: assigning a length-1 NA into a ZERO-row
      # data.frame errors ("replacement has 1 row, data has 0"), a case
      # dplyr::bind_rows handled. rep(NA, 0) = logical(0) works for 0 rows and
      # is identical to the recycled NA for n > 0.
      for (m in miss) d[[m]] <- rep(NA, nrow(d))
      d[, cols, drop = FALSE]
    })
  }
  out <- do.call(rbind, c(dfs, list(make.row.names = FALSE)))
  rownames(out) <- NULL
  out
}

# Why: the last two dplyr uses in FLOWS are group_by |> summarise (global.R
# lat_band reps; wi_loaders.R road_id/zipcode length aggregate). Owning this
# lets us drop library(dplyr) entirely (dependency-reduction SOP).
# What: groups df by the `by` columns and computes one row per distinct group
# with the named aggregations, ordered ASCENDING by the group columns — exactly
# matching dplyr::group_by(by) |> summarise(aggs, .groups = "drop"). Group
# columns come first (original types preserved), then the aggregation columns
# in definition order. Returns a base data.frame.
# How: split row indices by the group tuple, apply each aggregation to the
# group's sub-data.frame (original row order preserved, so an aggregation like
# `\d d$col[1]` reproduces dplyr::first), rbind, then sort by the group columns
# to reproduce dplyr's ascending group order.
# When: replaces dplyr group_by/summarise call sites.
# Impact: proven byte-identical to the two dplyr calls it replaces in
# tests/jobs/dep_reduction_equiv.R. The group key uses a "\r" paste separator;
# safe for FLOWS keys (numeric lat_band, character road_id/zipcode) which never
# contain it. Re-run the gate if grouping by free-text columns.
flows_group_aggregate <- function(df, by, aggs) {
  stopifnot(is.data.frame(df), length(by) >= 1L, is.list(aggs), length(aggs) >= 1L)
  if (nrow(df) == 0L) {
    empty <- df[0L, by, drop = FALSE]
    for (nm in names(aggs)) empty[[nm]] <- numeric(0)
    rownames(empty) <- NULL
    return(empty)
  }
  key <- do.call(paste, c(lapply(by, function(b) as.character(df[[b]])), sep = "\r"))
  idx <- split(seq_len(nrow(df)), key)
  # Build the result COLUMNWISE (group-key rows in one subset + one unlist per
  # aggregation) instead of one 1-row data.frame per group fed to rbind — the
  # rbind form was O(groups^2)-ish and the road_id/zipcode call site has ~100k
  # groups. Aggregations must return a length-1 atomic (non-factor) value,
  # which is the dplyr::summarise contract the dep_equiv gate proves.
  firsts <- vapply(idx, function(ix) ix[[1L]], integer(1))
  out <- df[firsts, by, drop = FALSE]
  for (nm in names(aggs)) {
    f <- aggs[[nm]]
    out[[nm]] <- unlist(lapply(idx, function(ix) f(df[ix, , drop = FALSE])), use.names = FALSE)
  }
  ord <- do.call(order, lapply(by, function(b) out[[b]]))
  out <- out[ord, , drop = FALSE]
  rownames(out) <- NULL
  out
}
