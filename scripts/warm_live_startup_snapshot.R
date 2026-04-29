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

mark_startup_warmer_active(project_dir = project_dir)
on.exit(clear_startup_warmer_active(), add = TRUE)

message(sprintf("[%s] warming live startup payload in %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), project_dir))
payload <- prefetch_live_startup_payload(force_refresh = FALSE, allow_stale = TRUE)
road_rows <- if (inherits(payload$roads, "sf")) nrow(payload$roads) else 0L
message(sprintf("[%s] warm complete: zip_rows=%d road_rows=%d", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), nrow(payload$polys), road_rows))
