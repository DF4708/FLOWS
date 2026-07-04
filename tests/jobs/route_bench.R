# -----------------------------------------------------------------------------
# route_bench.R — intrastate route latency benchmark.
#
# Mirrors the real server.R path: load the startup snapshot (polys + roads),
# build the routing graph once, then time plan_route_options over a corpus
# of Wisconsin OD pairs. Appends one JSON line per invocation to
# tests/continuous_results.jsonl so many runs build a latency DISTRIBUTION
# (p50/p95), not a single point estimate — the statistical foundation the
# testing strategy needs to prove "cross-country loads as fast as local".
#
# Usage:  Rscript tests/jobs/route_bench.R
# -----------------------------------------------------------------------------

suppressWarnings(suppressMessages({
  source("global.R", chdir = TRUE)
  library(jsonlite)
}))

# Write to the durable results file the runner + report both read
# (data/results/, on the project volume; see docs/CRASH_SURVIVAL.md). The old
# tests/ path was a split-brain: route_bench's samples landed there while the
# report read data/results/, so route_plan looked frozen. Keep the tests/
# fallback only if the durable dir is somehow absent.
RESULTS <- if (dir.exists("data/results")) {
  "data/results/continuous_results.jsonl"
} else {
  "tests/continuous_results.jsonl"
}
utc_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

emit <- function(record) {
  record$timestamp <- utc_now()
  cat(jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", na = "null", digits = 4),
      "\n", sep = "", file = RESULTS, append = TRUE)
}

# Memory-pressure used% stamped on each route_plan sample so the latency
# distribution can be CONDITIONED on memory pressure (fixed graph, yet p50/p95
# drift with the machine's memory state). Delegates to the CANONICAL
# implementation in R/resource_governor.R (already loaded via global.R above) —
# a local copy here re-created the page-size bug class across four files.
mem_used_pct <- function() {
  round(100 * tryCatch(system_memory_used_fraction(), error = function(e) NA_real_), 1)
}

# Wisconsin OD corpus — city-name queries resolvable by resolve_search_point.
# Spread across the state so routes exercise different graph regions and
# distances (short intra-metro to long cross-state).
OD_CORPUS <- list(
  list(from = "Milwaukee, WI",  to = "Madison, WI"),
  list(from = "Green Bay, WI",  to = "Milwaukee, WI"),
  list(from = "Madison, WI",    to = "La Crosse, WI"),
  list(from = "Eau Claire, WI", to = "Wausau, WI"),
  list(from = "Kenosha, WI",    to = "Superior, WI"),   # SE -> NW, longest
  list(from = "Appleton, WI",   to = "Racine, WI"),
  list(from = "Oshkosh, WI",    to = "Janesville, WI"),
  list(from = "Waukesha, WI",   to = "Sheboygan, WI")
)

main <- function() {
  # Load the warmed snapshot for the polys + roads (mirrors server startup).
  snap <- tryCatch(
    load_runtime_snapshot(STARTUP_MAP_SNAPSHOT_PATH, max_age_seconds = Inf),
    error = function(e) NULL
  )
  payload <- if (!is.null(snap)) (snap$payload %||% snap) else NULL
  if (is.null(payload) || is.null(payload$polys)) {
    emit(list(job = "route_bench", status = "skipped",
              reason = "no startup snapshot available"))
    cat("route_bench: no snapshot, skipped\n")
    return(invisible())
  }
  polys <- payload$polys
  roads <- payload$roads

  # Build the routing graph once (this is the ~2-4 s cold step server.R
  # amortises across all route requests).
  t_graph <- system.time({
    segs <- tryCatch(
      build_route_segments(polys, "live", roads_overlay = roads),
      error = function(e) NULL
    )
  })[["elapsed"]]
  emit(list(job = "route_bench_graph_build", seconds = t_graph,
            region = tryCatch(active_region_label(), error = function(e) "?")))

  if (is.null(segs) || nrow(segs) == 0) {
    emit(list(job = "route_bench", status = "skipped",
              reason = "build_route_segments returned no edges"))
    cat("route_bench: no route segments, skipped\n")
    return(invisible())
  }

  # Time each OD pair. route_segments is passed so the graph is reused —
  # this measures the pure planning latency, which is the number that must
  # stay < 1 s intrastate (and eventually < 4 s cross-country).
  latencies <- numeric(0)
  for (od in OD_CORPUS) {
    t <- system.time({
      res <- tryCatch(
        plan_route_options(od$from, od$to, polys, "live", route_segments = segs),
        error = function(e) NULL
      )
    })[["elapsed"]]
    ok <- !is.null(res) && length(res$routes %||% list()) > 0
    n_routes <- if (ok) length(res$routes) else 0L
    latencies <- c(latencies, t)
    emit(list(job = "route_plan", from = od$from, to = od$to,
              seconds = t, ok = ok, n_routes = n_routes,
              mem_pct = mem_used_pct(),
              region = tryCatch(active_region_label(), error = function(e) "?")))
  }

  # Summary distribution — the headline metric.
  if (length(latencies) > 0) {
    emit(list(
      job    = "route_bench_summary",
      n      = length(latencies),
      p50    = as.numeric(stats::median(latencies)),
      p95    = as.numeric(stats::quantile(latencies, 0.95)),
      mean   = mean(latencies),
      max    = max(latencies),
      graph_build_seconds = t_graph,
      region = tryCatch(active_region_label(), error = function(e) "?")
    ))
    cat(sprintf("route_bench: n=%d p50=%.3fs p95=%.3fs max=%.3fs graph=%.2fs\n",
                length(latencies), stats::median(latencies),
                stats::quantile(latencies, 0.95), max(latencies), t_graph))
  }
}

main()
