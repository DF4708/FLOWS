# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# Why: cold-start performance work needs visibility into which loaders are
# disproportionately slow. A small in-process timer with a roll-up summary
# lets us spot regressions ("compute_511_road_proximity_signal took 12 s")
# without instrumenting every callsite by hand or shipping a dependency.
# What: flows_time_step(label, expr) evaluates expr, returns its value, and
# records elapsed wall time in a session-level ring buffer plus a tagged
# console line. flows_timing_summary() prints a sorted rollup; flows_timing_
# clear() resets the buffer (useful before re-running a build).
# How: state lives in a private environment so timings persist across
# function calls in the same R process. Console messages use a fixed
# "[FLOWS-TIMING]" prefix so logs from the warmer Rscript and the foreground
# Shiny session are easy to grep.
# When: top-level loaders in server.R, prefetch_live_startup_payload, and
# the heavier helpers inside build_driving_roads_overlay / build_511_roads
# _overlay wrap their work in flows_time_step. Per-call overhead is one
# proc.time() pair plus a list-append; negligible against the operations
# being measured.
# Impact: enabled by default. Set FLOWS_TIMING=0 in the environment to
# silence both the console line and buffer accumulation.

.flows_timing_state <- new.env(parent = emptyenv())
.flows_timing_state$entries <- list()
.flows_timing_state$max_entries <- 2000L

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns TRUE unless FLOWS_TIMING is "0" / "false" in the
# environment.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
flows_timing_enabled <- function() {
  v <- Sys.getenv("FLOWS_TIMING", unset = "1")
  !identical(v, "0") && !identical(tolower(v), "false")
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Wraps an expression with elapsed-time measurement. Returns the
# expression's value unchanged. When timing is disabled, behaves as a no-op
# pass-through.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
flows_time_step <- function(label, expr, group = NULL) {
  if (!flows_timing_enabled()) return(force(expr))
  t0 <- proc.time()[[3]]
  result <- tryCatch(
    force(expr),
    error = function(e) {
      dt <- proc.time()[[3]] - t0
      message(sprintf("[FLOWS-TIMING] %-60s %8.3f s  ERROR: %s",
                      substr(as.character(label), 1, 60), dt, conditionMessage(e)))
      stop(e)
    }
  )
  dt <- proc.time()[[3]] - t0
  entry <- list(
    label   = as.character(label),
    group   = if (is.null(group)) NA_character_ else as.character(group),
    seconds = unname(dt),
    ts      = Sys.time()
  )
  n <- length(.flows_timing_state$entries)
  if (n >= .flows_timing_state$max_entries) {
    keep_from <- as.integer(n %/% 2L) + 1L
    .flows_timing_state$entries <- .flows_timing_state$entries[keep_from:n]
  }
  .flows_timing_state$entries[[length(.flows_timing_state$entries) + 1L]] <- entry
  group_tag <- if (!is.null(group)) sprintf(" [%s]", group) else ""
  message(sprintf("[FLOWS-TIMING] %-60s %8.3f s%s",
                  substr(as.character(label), 1, 60), dt, group_tag))
  result
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns and prints a data.frame of recorded entries sorted slowest
# first. `top` caps the number of rows printed; `group` filters by the
# optional group tag passed to flows_time_step.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
flows_timing_summary <- function(top = 25L, group = NULL) {
  entries <- .flows_timing_state$entries
  if (length(entries) == 0) {
    message("No FLOWS timing entries recorded.")
    return(invisible(NULL))
  }
  if (!is.null(group)) {
    entries <- Filter(function(e) identical(e$group, as.character(group)), entries)
    if (length(entries) == 0) {
      message(sprintf("No FLOWS timing entries with group=\"%s\".", group))
      return(invisible(NULL))
    }
  }
  df <- data.frame(
    label   = vapply(entries, function(e) e$label, character(1)),
    group   = vapply(entries, function(e) e$group, character(1)),
    seconds = vapply(entries, function(e) e$seconds, numeric(1)),
    stringsAsFactors = FALSE
  )
  df <- df[order(-df$seconds), , drop = FALSE]
  cat("\nFLOWS timing summary (slowest first):\n")
  print(utils::head(df, n = max(1L, as.integer(top))), row.names = FALSE)
  cat(sprintf("\nTotal recorded: %.2f s across %d entries.\n",
              sum(df$seconds), nrow(df)))
  invisible(df)
}
