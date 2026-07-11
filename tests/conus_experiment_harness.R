# -----------------------------------------------------------------------------
# CONUS experiment harness — scientific-method runner
#
# Every experiment is a self-contained record. The harness:
#   1. Verifies assumptions (falsified → REDESIGN, no measurement taken)
#   2. Runs regression gates (parse + smoke + SQA + mutation + equivalence)
#   3. Measures the baseline
#   4. Runs the intervention
#   5. Measures again
#   6. Compares against budgets
#   7. Appends the full record to tests/experiments.jsonl (append-only)
#   8. Rolls back on regression, records next_action = ROLL_BACK
#
# Usage:
#   Rscript tests/conus_experiment_harness.R baseline
#   Rscript tests/conus_experiment_harness.R run phase-1-nwps-24cores
#   Rscript tests/conus_experiment_harness.R report
#
# The experiment definitions live in tests/experiments/*.R — each returns a
# list with the fields shown below.
# -----------------------------------------------------------------------------

suppressWarnings(suppressMessages({
  library(jsonlite)
}))

# Durable, crash-safe persistence: results live under the project volume's
# data/results/ (never /tmp, /var/folders, or an OS scratchpad). Each write
# is flushed to disk so a crash between experiments cannot lose history.
EXPERIMENTS_LOG <- "data/results/experiments.jsonl"
EXPERIMENTS_DIR <- "tests/experiments"

# One-time migration of any legacy log so no records are lost when the
# durable location was introduced.
local({
  if (!dir.exists("data/results")) dir.create("data/results", recursive = TRUE, showWarnings = FALSE)
  legacy <- "tests/experiments.jsonl"
  if (file.exists(legacy) && !file.exists("data/results/.experiments.migrated")) {
    cat(paste(readLines(legacy, warn = FALSE), collapse = "\n"), "\n",
        sep = "", file = EXPERIMENTS_LOG, append = TRUE)
    file.create("data/results/.experiments.migrated")
  }
})

# ---------- helpers ----------------------------------------------------------

utc_now <- function() format(Sys.time(), format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

git_sha <- function() {
  tryCatch(
    trimws(system2("git", c("rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE)),
    error = function(e) NA_character_
  )
}

# Wraps expr with proc.time() so callers don't have to.
timed <- function(expr) {
  t0 <- proc.time()[[3]]
  value <- tryCatch(force(expr), error = function(e) structure(list(), error = conditionMessage(e)))
  list(seconds = proc.time()[[3]] - t0, value = value)
}

# Log every experiment result as one JSON line. Never truncates prior entries.
log_experiment <- function(record) {
  if (!dir.exists(dirname(EXPERIMENTS_LOG))) {
    dir.create(dirname(EXPERIMENTS_LOG), recursive = TRUE, showWarnings = FALSE)
  }
  line <- jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", na = "null", digits = 6)
  # Durable append: write through an explicit connection, flush it, close it
  # (commits to the OS page cache), then `sync` to push filesystem buffers to
  # disk. A crash after this returns cannot lose the record.
  con <- file(EXPERIMENTS_LOG, open = "at")
  on.exit(close(con), add = TRUE)
  cat(line, "\n", sep = "", file = con)
  flush(con)
  invisible(tryCatch(system2("sync"), error = function(e) NULL))
}

# ---------- assumption checking ----------------------------------------------

# Each assumption is a named function returning TRUE, FALSE, or a message.
check_assumptions <- function(assumptions) {
  results <- lapply(names(assumptions), function(nm) {
    fn <- assumptions[[nm]]
    res <- tryCatch(fn(), error = function(e) paste0("ERROR: ", conditionMessage(e)))
    list(
      name   = nm,
      passed = isTRUE(res),
      detail = if (isTRUE(res)) "ok" else as.character(res)
    )
  })
  all_ok <- all(vapply(results, function(r) isTRUE(r$passed), logical(1)))
  list(all_ok = all_ok, results = results)
}

# ---------- regression gates -------------------------------------------------

# Each gate is (name, command, acceptance_predicate). Runs Rscript in a
# subprocess so a crash in one gate doesn't take down the harness.
regression_gates <- function() {
  list(
    list(
      name        = "parse_all_files",
      command     = "Rscript",
      args        = local({
        # Write the parse check to a temp file rather than passing the
        # expression through -e — system2's arg-vector goes through the
        # shell, which interprets parentheses / semicolons unpredictably.
        tf <- tempfile(fileext = ".R")
        writeLines(c(
          "for (f in list.files('R', pattern='\\\\.R$', full.names=TRUE, recursive=TRUE)) parse(f)",
          "cat('ok\\n')"
        ), tf)
        tf
      }),
      accepts     = function(stdout) any(grepl("^ok$", stdout))
    ),
    list(
      name        = "runtime_smoke",
      command     = "Rscript",
      args        = "scripts/runtime_smoke_test.R",
      accepts     = function(stdout) any(grepl("Runtime smoke test passed", stdout))
    ),
    list(
      name        = "sqa_suite",
      command     = "Rscript",
      args        = "tests/sqa_runner.R",
      accepts     = function(stdout) any(grepl("All 8 SQA suites PASSED", stdout))
    ),
    list(
      name        = "mutation_harness",
      command     = "Rscript",
      args        = "tests/mutation_test.R",
      accepts     = function(stdout) any(grepl("Mutations killed: 13 / 13", stdout))
    ),
    list(
      name        = "modeled_road_equivalence",
      command     = "Rscript",
      args        = "tests/test_modeled_road_risk.R",
      accepts     = function(stdout) any(grepl("speedup: \\d+", stdout))
    )
  )
}

run_gate <- function(gate) {
  out_file <- tempfile(fileext = ".out")
  on.exit(unlink(out_file), add = TRUE)
  exit <- system2(gate$command, gate$args, stdout = out_file, stderr = out_file)
  stdout <- tryCatch(readLines(out_file, warn = FALSE), error = function(e) character(0))
  passed <- exit == 0 && gate$accepts(stdout)
  list(
    name      = gate$name,
    exit_code = exit,
    passed    = passed,
    tail      = utils::tail(stdout, 5)
  )
}

run_all_gates <- function() {
  gates <- regression_gates()
  results <- lapply(gates, run_gate)
  list(
    all_passed = all(vapply(results, function(r) isTRUE(r$passed), logical(1))),
    results    = results
  )
}

# ---------- baseline measurements --------------------------------------------

# Wisconsin-scale baselines. Captured once, then used as the reference point
# for every subsequent CONUS experiment. Deliberately narrow: only things we
# know how to measure autonomously on the current codebase.
measure_baselines <- function() {
  # Warm-cache warmer time (network sensitive but useful trend indicator).
  warmer_warm <- timed(system2("Rscript", "scripts/warm_live_startup_snapshot.R",
                               stdout = FALSE, stderr = FALSE))
  # sf reference-load time (data-scale sensitive, network insensitive).
  sf_load <- timed({
    suppressWarnings(suppressMessages({
      requireNamespace("sf", quietly = TRUE)
      sf::st_read("data/reference/wisconsin_reference.gpkg",
                  layer = "zctas", quiet = TRUE)
    }))
  })
  # OSM road load
  osm_load <- timed({
    tryCatch(readRDS("data/reference/wi_osm_roads.rds"),
             error = function(e) NULL)
  })
  list(
    warmer_warm_seconds = warmer_warm$seconds,
    sf_zctas_load_seconds = sf_load$seconds,
    osm_roads_load_seconds = osm_load$seconds
  )
}

# ---------- CLI dispatch -----------------------------------------------------

cmd_baseline <- function() {
  cat("== FLOWS baseline run ==\n")
  cat("Verifying regression gates first...\n")
  gates <- run_all_gates()
  if (!gates$all_passed) {
    cat("REFUSING: baseline is only valid on a green codebase.\n")
    for (r in gates$results) {
      cat(sprintf("  [%s] %s (exit %d)\n",
                  if (isTRUE(r$passed)) "OK" else "FAIL",
                  r$name, r$exit_code))
    }
    quit(status = 1)
  }
  cat("All regression gates green. Measuring baselines...\n")
  measurements <- measure_baselines()
  record <- list(
    id             = "baseline-wisconsin",
    timestamp      = utc_now(),
    git_sha        = git_sha(),
    type           = "baseline",
    measurements   = measurements,
    gates          = gates$results,
    conclusion     = "BASELINE_CAPTURED",
    next_action    = "PROCEED_TO_PHASE_1"
  )
  log_experiment(record)
  cat("\nBaseline captured:\n")
  for (nm in names(measurements)) {
    cat(sprintf("  %-30s %8.3f s\n", nm, measurements[[nm]]))
  }
  cat(sprintf("\nRecorded to %s\n", EXPERIMENTS_LOG))
}

cmd_run <- function(experiment_id) {
  file <- file.path(EXPERIMENTS_DIR, paste0(experiment_id, ".R"))
  if (!file.exists(file)) {
    cat(sprintf("No such experiment: %s\n", file))
    quit(status = 1)
  }
  cat(sprintf("== Running experiment %s ==\n", experiment_id))
  spec <- source(file, local = new.env(parent = globalenv()))$value
  stopifnot(is.list(spec),
            all(c("hypothesis", "assumptions", "intervention",
                  "baseline_measure", "post_measure",
                  "budgets", "rollback") %in% names(spec)))

  # Assumptions
  cat("Checking assumptions...\n")
  a <- check_assumptions(spec$assumptions)
  for (r in a$results) {
    cat(sprintf("  [%s] %s — %s\n",
                if (r$passed) "OK" else "FAIL", r$name, r$detail))
  }
  if (!a$all_ok) {
    log_experiment(list(
      id = experiment_id, timestamp = utc_now(), git_sha = git_sha(),
      hypothesis = spec$hypothesis, assumptions = a$results,
      conclusion = "REDESIGN",
      next_action = "REDESIGN_ASSUMPTIONS_FALSIFIED"
    ))
    quit(status = 2)
  }

  cat("Regression gates before intervention...\n")
  pre_gates <- run_all_gates()
  if (!pre_gates$all_passed) {
    cat("REFUSING: pre-experiment state is not green.\n")
    quit(status = 2)
  }

  cat("Measuring baseline...\n")
  baseline <- spec$baseline_measure()

  cat("Applying intervention...\n")
  intervention_ok <- tryCatch({ spec$intervention(); TRUE },
                              error = function(e) {
                                cat("Intervention failed: ", conditionMessage(e), "\n")
                                FALSE
                              })
  if (!intervention_ok) {
    log_experiment(list(
      id = experiment_id, timestamp = utc_now(), git_sha = git_sha(),
      hypothesis = spec$hypothesis,
      conclusion = "INTERVENTION_ERROR",
      next_action = "REDESIGN"
    ))
    quit(status = 3)
  }

  cat("Measuring post-intervention state...\n")
  post <- spec$post_measure()

  cat("Regression gates after intervention...\n")
  post_gates <- run_all_gates()
  if (!post_gates$all_passed) {
    cat("Regression detected. Rolling back.\n")
    tryCatch(spec$rollback(), error = function(e) {
      cat("Rollback ALSO failed. Manual intervention required.\n")
    })
    log_experiment(list(
      id = experiment_id, timestamp = utc_now(), git_sha = git_sha(),
      hypothesis = spec$hypothesis,
      baseline_measurement = baseline,
      post_measurement = post,
      gates_pre = pre_gates$results,
      gates_post = post_gates$results,
      conclusion = "REFUTED",
      next_action = "ROLL_BACK"
    ))
    quit(status = 4)
  }

  # Compare against budgets
  budget_ok <- TRUE
  for (nm in names(spec$budgets)) {
    if (is.null(post[[nm]])) next
    if (!isTRUE(post[[nm]] <= spec$budgets[[nm]])) {
      cat(sprintf("  BUDGET BUSTED: %s = %g > %g\n",
                  nm, post[[nm]], spec$budgets[[nm]]))
      budget_ok <- FALSE
    }
  }

  effect <- Map(function(a, b) if (is.numeric(a) && is.numeric(b)) b - a else NA,
                baseline, post[names(baseline)])
  log_experiment(list(
    id = experiment_id, timestamp = utc_now(), git_sha = git_sha(),
    hypothesis = spec$hypothesis,
    assumptions = a$results,
    baseline_measurement = baseline,
    post_measurement = post,
    effect = effect,
    budgets = spec$budgets,
    conclusion = if (budget_ok) "SUPPORTED" else "PARTIAL",
    next_action = if (budget_ok) "LAND" else "REDESIGN"
  ))
  cat(sprintf("Experiment complete. Conclusion: %s\n",
              if (budget_ok) "SUPPORTED" else "PARTIAL"))
}

cmd_report <- function() {
  if (!file.exists(EXPERIMENTS_LOG)) {
    cat("No experiments recorded yet. Run `baseline` first.\n")
    return(invisible(NULL))
  }
  lines <- readLines(EXPERIMENTS_LOG, warn = FALSE)
  cat(sprintf("=== FLOWS experiment log (%d records) ===\n\n", length(lines)))
  cat(sprintf("  %-40s %-14s %-14s %s\n",
              "ID", "Type", "Conclusion", "Next"))
  cat(sprintf("  %-40s %-14s %-14s %s\n",
              strrep("-", 40), strrep("-", 14), strrep("-", 14),
              strrep("-", 20)))
  for (ln in lines) {
    rec <- tryCatch(jsonlite::fromJSON(ln), error = function(e) NULL)
    if (is.null(rec)) next
    cat(sprintf("  %-40s %-14s %-14s %s\n",
                substr(rec$id %||% "?", 1, 40),
                substr(rec$type %||% "experiment", 1, 14),
                substr(rec$conclusion %||% "?", 1, 14),
                substr(rec$next_action %||% "?", 1, 20)))
  }
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

# ---------- entry point ------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0) {
  cat("usage:\n")
  cat("  Rscript tests/conus_experiment_harness.R baseline\n")
  cat("  Rscript tests/conus_experiment_harness.R run <experiment-id>\n")
  cat("  Rscript tests/conus_experiment_harness.R report\n")
  quit(status = 1)
}

switch(args[[1]],
  baseline = cmd_baseline(),
  run      = if (length(args) < 2) {
               cat("run requires an experiment id\n")
               quit(status = 1)
             } else cmd_run(args[[2]]),
  report   = cmd_report(),
  { cat(sprintf("unknown command: %s\n", args[[1]])); quit(status = 1) }
)
