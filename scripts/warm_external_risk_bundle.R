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

# Pre-load native libraries that the 511 / NWS / EPA fetchers rely on. macOS
# fork() doesn't reliably handle on-demand dyn.load of native .so files in
# the child — child processes that try to load curl/httr2's URL parser
# segfault when the parent has not already touched those code paths. Forcing
# eager load in the parent here makes any later parallel::mcparallel /
# mclapply forks inherit the already-mapped libraries safely.
suppressWarnings(suppressMessages({
  invisible(tryCatch(curl::curl_version(), error = function(e) NULL))
  # Touch the URL-parsing path explicitly: this is what the iter 7 segfault
  # crashed on (httr2::req_retry -> url_parse -> dyn.load).
  invisible(tryCatch({
    if (requireNamespace("curl", quietly = TRUE)) {
      curl::curl_parse_url("https://example.com/")
    }
  }, error = function(e) NULL))
  invisible(tryCatch(httr2::request("https://example.com"), error = function(e) NULL))
}))

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

# Speculative parallel 511 prefetch in a forked child: the parent has just
# pre-loaded curl/httr2 above so the child should inherit the mapped libs
# and avoid the dyn.load segfault. Catches errors defensively — if the
# child fails for any reason we fall through to the sequential path inside
# compute_external_risk_bundle.
job_511_prefetch <- if (isTRUE(include_transport) && .Platform$OS.type != "windows") {
  parallel::mcparallel({
    overlay <- tryCatch(build_511_roads_overlay(horizon_key), error = function(e) NULL)
    msg_zip <- tryCatch(compute_511_message_sign_zip_signal(horizon_key), error = function(e) NULL)
    alert_zip <- tryCatch(compute_511_alert_zip_signal(horizon_key), error = function(e) NULL)
    transport <- tryCatch(compute_511_zip_transport_risk(horizon_key), error = function(e) NULL)
    list(overlay = overlay, msg_zip = msg_zip, alert_zip = alert_zip, transport = transport)
  })
} else NULL

baseline <- flows_time_step(
  sprintf("warmer: build_forecast_baseline (%s)", horizon_key),
  build_forecast_baseline(horizon_key),
  group = "warmer-orch"
)
baseline <- flows_time_step(
  sprintf("warmer: initialize_zip_alert_fields (%s)", horizon_key),
  initialize_zip_alert_fields(baseline),
  group = "warmer-orch"
)

# Defer mccollect to a hook that fires RIGHT BEFORE the transport step inside
# compute_external_risk_bundle. The parent runs the lighter family steps (~10s
# combined) sequentially while the child runs the heavy 511 pipeline (~10s)
# in parallel; when the bundle reaches its transport step, the hook collects
# the child's results and seeds the parent's cache so the transport step is a
# fast cache hit. Wall time = max(non_transport_families, child_511) + small
# epilogue, vs. fully sequential which is sum-of-all.
prefetch_hook <- if (!is.null(job_511_prefetch)) {
  function() {
    prefetched <- flows_time_step(
      sprintf("warmer: collect 511 prefetch (%s)", horizon_key),
      parallel::mccollect(job_511_prefetch, wait = TRUE),
      group = "warmer-orch"
    )
    prefetch_payload <- if (is.list(prefetched) && length(prefetched) > 0) prefetched[[1]] else NULL
    if (is.list(prefetch_payload) && !inherits(prefetch_payload, "try-error")) {
      ttl_511 <- if (has_wi511_key()) ALERT_TTL_SECONDS else FORECAST_TTL_SECONDS
      if (!is.null(prefetch_payload$overlay))   cache_put("derived", paste0("wi511-roads-overlay-", horizon_key),  prefetch_payload$overlay,   ttl_seconds = ttl_511)
      if (!is.null(prefetch_payload$msg_zip))   cache_put("derived", paste0("wi511-message-sign-zip-", horizon_key), prefetch_payload$msg_zip,   ttl_seconds = ttl_511)
      if (!is.null(prefetch_payload$alert_zip)) cache_put("derived", paste0("wi511-alert-zip-signal-", horizon_key), prefetch_payload$alert_zip, ttl_seconds = ttl_511)
      if (!is.null(prefetch_payload$transport)) cache_put("derived", paste0("wi511-zip-transport-", horizon_key),    prefetch_payload$transport, ttl_seconds = ttl_511)
    }
  }
} else NULL

bundle_info <- flows_time_step(
  sprintf("warmer: load_external_risk_bundle (%s)", horizon_key),
  load_external_risk_bundle(
    baseline,
    horizon_key = horizon_key,
    selected_features = selected_features,
    include_transport = include_transport,
    allow_stale = FALSE,
    schedule_refresh = FALSE,
    force_sync = TRUE,
    project_dir = project_dir,
    pre_transport_hook = prefetch_hook
  ),
  group = "warmer-orch"
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
