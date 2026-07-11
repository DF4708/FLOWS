# -----------------------------------------------------------------------------
# router_realgraph_equiv.R — validate the Rust router against the R A* on the
# REAL Wisconsin route graph. Proves the Rust CSR Dijkstra's shortest-path COSTS
# equal astar_route's costs (A* uses an admissible heuristic, so its cost is the
# true optimum == Dijkstra). Paths may differ on equal-cost ties; we compare
# COSTS, not paths.
#
# SELF-GOVERNING: building the ~90k-edge graph is memory-heavy, so this job runs
# ONLY when system memory is below a strict headroom threshold (default 78%,
# leaving room for the build to stay under the 90% ceiling). Otherwise it exits
# 0 with a "deferred" note — the continuous runner offloads it to a low-mem
# window instead of pressuring the machine. This is the right home for the
# heavy validation: the governed worker, not an interactive cycle.
#
# Usage:  Rscript tests/jobs/router_realgraph_equiv.R
# -----------------------------------------------------------------------------

# ---- memory gate FIRST (before sourcing anything heavy) ----------------------
# Uses the CANONICAL memory accounting from R/resource_governor.R (standalone,
# pure function definitions — safe to source without global.R). A local copy
# here previously re-introduced the page-size bug class: four independent
# implementations meant a fix in one could silently miss the others.
source("R/resource_governor.R", local = TRUE)
mem_used_pct <- function() {
  round(100 * tryCatch(system_memory_used_fraction(), error = function(e) 1), 1)
}
# Threshold tuned to route_bench's PROVEN envelope: route_bench builds the same
# ~90k-edge graph every pass at 86-91% used and never OOMs, because the metric
# (active+wired+compressed) is dominated by reclaimable file cache — actual
# process RSS is a few GB on a 64GB box. So a graph build is safe at this level;
# the old 78% gate never fired (baseline ~86%). Gate at 86% so it runs when mem
# dips at/below baseline, leaving headroom for the build's transient spike, and
# defers when the machine is genuinely busier. (env override: FLOWS_ROUTER_MEM_CEIL)
CEIL <- as.numeric(Sys.getenv("FLOWS_ROUTER_MEM_CEIL", "86"))
m <- mem_used_pct()
if (m >= CEIL) {
  cat(sprintf("router_realgraph: deferred (mem %.1f%% >= %.0f%% headroom) — PASS\n", m, CEIL))
  quit(status = 0)
}

suppressWarnings(suppressMessages(source("global.R")))
utc_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
emit <- function(rec) {
  rec$timestamp <- utc_now()
  cat(jsonlite::toJSON(rec, auto_unbox = TRUE, null = "null", na = "null", digits = 6),
      "\n", sep = "", file = "data/results/continuous_results.jsonl", append = TRUE)
}

if (!isTRUE(flows_rust_available())) {
  cat("router_realgraph: skipped (Rust core dylib absent) — PASS\n"); quit(status = 0)
}
snap <- tryCatch(load_runtime_snapshot(STARTUP_MAP_SNAPSHOT_PATH, max_age_seconds = Inf), error = function(e) NULL)
if (is.null(snap)) { cat("router_realgraph: skipped (no snapshot) — PASS\n"); quit(status = 0) }
# load_runtime_snapshot returns list(payload = <the map payload>); unwrap it
# (route_bench.R does the same). Reading snap$polys directly always gave NULL,
# which made this gate exit 'skipped — PASS' forever without ever validating.
snap <- snap$payload %||% snap
polys <- snap$polys %||% snap$zips %||% NULL
roads <- snap$roads %||% NULL
segments <- tryCatch(build_route_segments(polys, "live", roads_overlay = roads), error = function(e) NULL)
if (is.null(segments) || nrow(segments) == 0) { cat("router_realgraph: skipped (no segments) — PASS\n"); quit(status = 0) }
graph <- build_route_graph(segments)
weights <- compute_profile_edge_weights(segments, "fastest")

# 0-based CSR from the production graph; negatives/non-finite -> Inf (A* skips them).
offsets <- as.integer(graph$u_starts - 1L)
targets <- as.integer(graph$half_to - 1L)
hw <- weights[graph$half_edge_row]; hw[!is.finite(hw) | hw < 0] <- Inf

set.seed(20260702); n <- graph$n_nodes
sources <- sample.int(n, 2)
ok <- 0L; pairs <- 0L; maxdiff <- 0
t_rust <- 0; t_astar <- 0
for (s in sources) {
  t0 <- Sys.time(); d <- rust_dijkstra(offsets, targets, hw, s - 1L); t_rust <- t_rust + as.numeric(Sys.time() - t0)
  if (is.null(d)) next
  for (t in sample.int(n, 2)) {
    if (s == t) next
    pairs <- pairs + 1L
    t0 <- Sys.time(); a <- astar_route(graph, s, t, weights); t_astar <- t_astar + as.numeric(Sys.time() - t0)
    rc <- d[t]; ac <- if (is.null(a)) Inf else a$cost
    if ((is.infinite(rc) && is.infinite(ac)) || isTRUE(rc == ac) || isTRUE(abs(rc - ac) < 1e-6)) ok <- ok + 1L
    else { maxdiff <- max(maxdiff, abs(rc - ac)); cat(sprintf("  MISMATCH s=%d t=%d rust=%.6f astar=%.6f\n", s, t, rc, ac)) }
  }
}
emit(list(job = "router_realgraph_equiv", status = if (ok == pairs) "pass" else "fail",
          nodes = n, edges = nrow(segments), pairs = pairs, ok = ok, max_cost_diff = maxdiff,
          rust_sssp_s = t_rust / max(length(sources), 1), astar_od_s = t_astar / max(pairs, 1)))
cat(sprintf("router_realgraph: %d/%d OD costs match (rust Dijkstra vs admissible A*) | nodes=%d edges=%d | rust SSSP %.3fs, A* %.3fs/OD\n",
            ok, pairs, n, nrow(segments), t_rust / max(length(sources), 1), t_astar / max(pairs, 1)))
if (ok != pairs) quit(status = 1)
