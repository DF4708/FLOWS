# -----------------------------------------------------------------------------
# continuous_report.R — summarise the continuous runner's accumulated results.
#
# Reads tests/continuous_results.jsonl and prints per-metric distributions
# (n, p50, p95, mean, sd, min, max) so the autonomous progress updates are
# data-driven. Variance across passes is the point: a stable p95 with low
# sd means the measurement is trustworthy; high sd flags a flaky metric
# worth investigating.
#
# Usage:  Rscript tests/continuous_report.R
# -----------------------------------------------------------------------------

suppressWarnings(suppressMessages(library(jsonlite)))

# Durable results moved to data/results/ (see docs/CRASH_SURVIVAL.md); fall
# back to the legacy tests/ path only if the durable file is absent.
f <- if (file.exists("data/results/continuous_results.jsonl")) {
  "data/results/continuous_results.jsonl"
} else {
  "tests/continuous_results.jsonl"
}
if (!file.exists(f)) { cat("no results yet\n"); quit() }

lines <- readLines(f, warn = FALSE)
recs <- lapply(lines, function(l) tryCatch(jsonlite::fromJSON(l), error = function(e) NULL))
recs <- Filter(Negate(is.null), recs)

# Collect seconds by job label.
by_job <- list()
gate_status <- list()
for (r in recs) {
  job <- r$job %||% "?"
  if (!is.null(r$seconds) && is.numeric(r$seconds)) {
    by_job[[job]] <- c(by_job[[job]] %||% numeric(0), r$seconds)
  }
  if (!is.null(r$status)) {
    gate_status[[job]] <- c(gate_status[[job]] %||% character(0), r$status)
  }
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

fmt <- function(x) sprintf("%.3f", x)

cat(sprintf("=== FLOWS continuous test runner — %d records ===\n\n", length(recs)))

# Gate pass rates
cat("Regression gates (pass rate across passes):\n")
for (g in c("smoke", "sqa", "mutation", "equiv", "dep_equiv", "rust_equiv")) {
  st <- gate_status[[g]]
  if (is.null(st)) next
  n <- length(st); npass <- sum(st == "pass")
  cat(sprintf("  %-10s %d/%d pass (%.0f%%)\n", g, npass, n, 100 * npass / n))
}

cat("\nLatency distributions (seconds):\n")
cat(sprintf("  %-28s %4s %8s %8s %8s %8s\n", "metric", "n", "p50", "p95", "mean", "sd"))
cat(sprintf("  %-28s %4s %8s %8s %8s %8s\n",
            strrep("-", 28), "----", strrep("-", 8), strrep("-", 8),
            strrep("-", 8), strrep("-", 8)))
for (job in names(by_job)) {
  v <- by_job[[job]]
  if (length(v) == 0) next
  cat(sprintf("  %-28s %4d %8s %8s %8s %8s\n",
              substr(job, 1, 28), length(v),
              fmt(stats::median(v)),
              fmt(as.numeric(stats::quantile(v, 0.95))),
              fmt(mean(v)),
              fmt(if (length(v) > 1) stats::sd(v) else 0)))
}

# Route-plan headline (the CONUS metric).
rp <- by_job[["route_plan"]]
if (!is.null(rp) && length(rp) > 0) {
  cat(sprintf("\nHEADLINE — route plan latency: n=%d  p50=%.2fs  p95=%.2fs  (target: hold p95 flat as graph grows)\n",
              length(rp), stats::median(rp), as.numeric(stats::quantile(rp, 0.95))))
}
