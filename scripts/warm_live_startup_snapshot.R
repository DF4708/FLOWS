# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1L && nzchar(as.character(args[[1]]))) args[[1]] else "."
project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
setwd(project_dir)

source(file.path(project_dir, "global.R"), chdir = TRUE)

# Pre-load native libs (curl, httr2 URL parser) so any later parallel::
# mclapply / mcparallel forks inherit the mapped libraries safely. Without
# this, macOS forks segfault during dyn.load on the first child to need
# httr2's URL-parsing path. See iter 7/9 in the optimisation log.
suppressWarnings(suppressMessages({
  invisible(tryCatch(curl::curl_version(), error = function(e) NULL))
  invisible(tryCatch({
    if (requireNamespace("curl", quietly = TRUE)) curl::curl_parse_url("https://example.com/")
  }, error = function(e) NULL))
  invisible(tryCatch(httr2::request("https://example.com"), error = function(e) NULL))
}))

mark_startup_warmer_active(project_dir = project_dir)
on.exit(clear_startup_warmer_active(), add = TRUE)

message(sprintf("[%s] warming live startup payload in %s (region: %s | %s)",
                format(Sys.time(), "%Y-%m-%d %H:%M:%S"), project_dir,
                tryCatch(active_region_label(), error = function(e) "unknown"),
                tryCatch(resource_posture_line(), error = function(e) "resource: unknown")))
# Hold before the memory-heavy build if the system is already near its
# ceiling (another process spiked). Proceeds after headroom or a timeout so
# the warmer still makes progress on a sustained-busy machine.
invisible(tryCatch(wait_for_memory_headroom(ceiling = 0.90, timeout_seconds = 60),
                   error = function(e) TRUE))
payload <- prefetch_live_startup_payload(force_refresh = FALSE, allow_stale = TRUE)
road_rows <- if (inherits(payload$roads, "sf")) nrow(payload$roads) else 0L
message(sprintf("[%s] warm complete: zip_rows=%d road_rows=%d", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), nrow(payload$polys), road_rows))
