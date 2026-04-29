# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1L && nzchar(as.character(args[[1]]))) args[[1]] else "."
horizon_key <- if (length(args) >= 2L && nzchar(as.character(args[[2]]))) args[[2]] else "live"
feature_arg <- if (length(args) >= 3L) as.character(args[[3]]) else ""
include_transport <- isTRUE(length(args) >= 4L && as.character(args[[4]]) %in% c("1", "true", "TRUE", "yes"))

project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
setwd(project_dir)

source(file.path(project_dir, "global.R"), chdir = TRUE)

selected_features <- normalize_feature_selection(
  if (nzchar(trimws(feature_arg))) unlist(strsplit(feature_arg, ",", fixed = TRUE), use.names = FALSE) else character(0)
)

mark_external_bundle_warmer_active(
  horizon_key = horizon_key,
  selected_features = selected_features,
  include_transport = include_transport,
  project_dir = project_dir
)
on.exit(
  clear_external_bundle_warmer_active(
    horizon_key = horizon_key,
    selected_features = selected_features,
    include_transport = include_transport
  ),
  add = TRUE
)

message(sprintf(
  "[%s] warming external bundle horizon=%s features=%s transport=%s",
  format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
  horizon_key,
  paste(selected_features, collapse = ","),
  include_transport
))

baseline <- build_forecast_baseline(horizon_key)
baseline <- initialize_zip_alert_fields(baseline)
bundle_info <- load_external_risk_bundle(
  baseline,
  horizon_key = horizon_key,
  selected_features = selected_features,
  include_transport = include_transport,
  allow_stale = FALSE,
  schedule_refresh = FALSE,
  force_sync = TRUE,
  project_dir = project_dir
)
bundle <- bundle_info$bundle %||% data.frame()

message(sprintf(
  "[%s] external bundle warm complete: state=%s rows=%d cols=%d",
  format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
  as.character(bundle_info$state %||% "unknown"),
  nrow(bundle),
  ncol(bundle)
))

# Time-horizon decoupling: a per-horizon bundle is the live data with a
# decay function applied. Once one horizon (especially "live") is built,
# the underlying fetcher caches are hot, so deriving the others in this
# same R session is cheap (~1-4 s each vs. minutes cold). Eagerly populating
# every horizon here means the user never pays "first horizon click" lag.
follow_up_horizons <- if (identical(horizon_key, "live")) {
  c("24h", "48h", "72h")
} else {
  setdiff(c("live", "24h", "48h", "72h"), horizon_key)
}
for (other_horizon in follow_up_horizons) {
  cache_name <- external_bundle_cache_name(other_horizon, selected_features, include_transport = include_transport)
  if (!is.null(cache_get("derived", cache_name))) next
  fresh_age <- external_bundle_fresh_age_seconds(other_horizon)
  snap_path <- external_bundle_snapshot_path(other_horizon, selected_features, include_transport = include_transport)
  persisted <- load_external_bundle_snapshot(snap_path, max_age_seconds = fresh_age)
  if (!is.null(persisted) && isTRUE(persisted$complete)) {
    cache_put("derived", cache_name, persisted$bundle, ttl_seconds = fresh_age)
    next
  }
  message(sprintf("[%s] deriving follow-up horizon=%s",
                  format(Sys.time(), "%Y-%m-%d %H:%M:%S"), other_horizon))
  follow_baseline <- build_forecast_baseline(other_horizon)
  follow_baseline <- initialize_zip_alert_fields(follow_baseline)
  follow_info <- load_external_risk_bundle(
    follow_baseline,
    horizon_key = other_horizon,
    selected_features = selected_features,
    include_transport = include_transport,
    allow_stale = FALSE,
    schedule_refresh = FALSE,
    force_sync = TRUE,
    project_dir = project_dir
  )
  message(sprintf("[%s] follow-up horizon=%s state=%s rows=%d",
                  format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                  other_horizon,
                  as.character(follow_info$state %||% "unknown"),
                  nrow(follow_info$bundle %||% data.frame())))
}
