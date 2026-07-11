# -----------------------------------------------------------------------------
# rust_core.R — optional Rust compute core (libflows_core) loader.
#
# The R implementations remain the SOURCE OF TRUTH and the default. This file
# adds an OPTIONAL fast path: if the compiled Rust core (rust/flows-core) is
# present, load it once at startup so its byte-identical C-ABI kernels can be
# called from R via .C(). If it is absent or fails to load, everything falls
# back to pure R with no error — the app never depends on the dylib existing.
#
# Fork-safety: the load happens at global.R source time, BEFORE any
# parallel::mclapply fork in the routing/forecast paths. A dyn.load'd mapping is
# inherited by forked children, so .C() calls work in the workers too.
#
# NOTE: this file is sourced BEFORE R/util.R (alphabetical order), so it must
# use base R only — no %||% or other util helpers at load time.
# -----------------------------------------------------------------------------

# Load state lives in a private env so re-sourcing global.R can't leave a stale
# handle around; the `loaded` flag guards against double dyn.load.
.flows_rust_state <- new.env(parent = emptyenv())
.flows_rust_state$loaded <- FALSE
.flows_rust_state$path <- NA_character_

# Why: the dylib lives under rust/target and its name/extension is
# platform-specific; callers should not hardcode the path.
# What: returns the first existing libflows_core dynamic library path (release
# preferred over debug), or NA_character_ if none is built.
# How: builds candidate paths from getwd() and the platform extension, returns
# the first that exists.
# When: called once by flows_rust_try_load at startup.
# Impact: if the project is launched from a non-root working directory the
# paths miss and the core is treated as absent (pure-R fallback) — safe.
flows_rust_dylib_path <- function() {
  ext <- if (identical(Sys.info()[["sysname"]], "Darwin")) "dylib" else "so"
  fname <- paste0("libflows_core.", ext)
  cand <- c(
    file.path(getwd(), "rust", "target", "release", fname),
    file.path(getwd(), "rust", "target", "debug", fname)
  )
  hit <- cand[file.exists(cand)]
  if (length(hit) == 0L) return(NA_character_)
  p <- hit[[1L]]
  # Security: dyn.load runs native code IN-process. The path is resolved from
  # getwd(), so if the app is ever launched with an attacker-controlled cwd a
  # planted dylib would execute. Refuse to load a dylib that is owned by
  # someone else or is group/other-writable (i.e. that another account could
  # have written). On any stat failure, treat as absent (pure-R fallback).
  info <- tryCatch(file.info(p), error = function(e) NULL)
  if (is.null(info) || is.na(info$uid)) return(NA_character_)
  me <- tryCatch(as.integer(system2("id", "-u", stdout = TRUE)), error = function(e) NA_integer_)
  if (!is.na(me) && !is.na(info$uid) && info$uid != me) return(NA_character_)
  # Reject group- or other-writable (octal 0022). strtoi(format(octmode),8) is
  # the unambiguous decimal perm value.
  mode <- tryCatch(strtoi(format(info$mode), 8L), error = function(e) NA_integer_)
  if (!is.na(mode) && bitwAnd(mode, strtoi("22", 8L)) != 0L) return(NA_character_)
  p
}

# Why: the Rust core is optional; loading must never abort startup.
# What: attempts to dyn.load the dylib once; returns TRUE on success, FALSE if
# absent or on any load error. Idempotent (guarded by the loaded flag).
# How: tryCatch around dyn.load; records success + path in the state env.
# When: invoked at source time (below) and defensively before first use.
# Impact: a FALSE result means every kernel wrapper returns NULL and callers
# use their R implementation.
flows_rust_try_load <- function() {
  if (isTRUE(.flows_rust_state$loaded)) return(TRUE)
  p <- flows_rust_dylib_path()
  if (is.na(p)) return(FALSE)
  ok <- tryCatch({ dyn.load(p); TRUE }, error = function(e) FALSE)
  .flows_rust_state$loaded <- isTRUE(ok)
  .flows_rust_state$path <- if (isTRUE(ok)) p else NA_character_
  isTRUE(ok)
}

# Why: callers need a cheap predicate to decide fast-path vs R fallback.
# What: TRUE iff the Rust core loaded successfully.
# How: reads the state flag.
# When: at the top of every kernel wrapper.
# Impact: gates all Rust usage; FALSE keeps the app fully on R.
flows_rust_available <- function() isTRUE(.flows_rust_state$loaded)

# Why: piecewise_score is the most-used scoring primitive (~20 call sites) and
# the Rust batch kernel is ~200x faster than the R vapply loop / ~10x the
# vectorised R form; this wrapper exposes it with a safe contract.
# What: returns the length-n numeric vector of piecewise scores computed by the
# Rust core, or NULL if the core is unavailable (so callers fall back to R).
# Byte-identical to R piecewise_score / vector_piecewise_score_rowwise for
# scalar thresholds (proven in tests/jobs/rust_integration_equiv.R).
# How: .C() into flows_piecewise_score_batch (scalar thresholds, n values).
# When: LIVE in production — vector_piecewise_score (R/scoring.R) dispatches
# here first and falls back to the pure-R form when this returns NULL.
# Impact: a wrong length or NAOK handling here would corrupt scores; the
# equivalence gate guards against that on every runner pass.
rust_piecewise_score <- function(values, low, medium, high) {
  if (!flows_rust_available()) return(NULL)
  # Scalar-threshold contract: the batch kernel dereferences exactly one
  # double per threshold — a length-0 threshold would be an out-of-bounds
  # read, and length>1 would be silently ignored. Fall back to R instead.
  if (length(low) != 1L || length(medium) != 1L || length(high) != 1L) return(NULL)
  n <- length(values)
  if (n == 0L) return(numeric(0))
  tryCatch(
    .C("flows_piecewise_score_batch",
       values = as.double(values), n = as.integer(n),
       low = as.double(low), medium = as.double(medium), high = as.double(high),
       out = double(n), NAOK = TRUE)$out,
    error = function(e) NULL
  )
}

# Why: vector_piecewise_score_rowwise is the HOTTEST scoring path — the per-zip
# risk builder with spatially-varying (per-element) thresholds. This wrapper
# offloads it to the Rust rowwise kernel.
# What: returns the length-n numeric vector from the Rust core, or NULL if the
# core is unavailable so callers fall back to R. Byte-identical to
# vector_piecewise_score_rowwise (proven in the rust_equiv gate).
# How: recycles threshold vectors to n (mirrors the R form), then .C() into
# flows_piecewise_score_rowwise_batch.
# When: the per-zip / per-road risk recompute.
# Impact: guarded by the rust_equiv gate on every runner pass; a divergence
# would fail sqa/mutation immediately.
rust_piecewise_score_rowwise <- function(values, low, mid, high) {
  if (!flows_rust_available()) return(NULL)
  values <- suppressWarnings(as.numeric(values))
  low <- suppressWarnings(as.numeric(low))
  mid <- suppressWarnings(as.numeric(mid))
  high <- suppressWarnings(as.numeric(high))
  n <- max(length(values), length(low), length(mid), length(high))
  if (n <= 0L) return(numeric(0))
  values <- rep_len(values, n); low <- rep_len(low, n)
  mid <- rep_len(mid, n); high <- rep_len(high, n)
  tryCatch(
    .C("flows_piecewise_score_rowwise_batch",
       values = as.double(values), n = as.integer(n),
       low = as.double(low), mid = as.double(mid), high = as.double(high),
       out = double(n), NAOK = TRUE)$out,
    error = function(e) NULL
  )
}

# Why: the CONUS router foundation — offload single-source shortest paths to the
# Rust CsrGraph Dijkstra (the base the contraction-hierarchy router builds on).
# What: given a 0-based CSR graph (offsets length n+1, targets/weights length m)
# and a 0-based source, returns the length-n distance vector (Inf unreachable),
# or NULL if the Rust core is unavailable so callers fall back to R.
# How: .C() into flows_dijkstra_c.
# When: router ingest + (later) CH query paths; NOT yet wired into production
# route planning — proven against a pure-R Dijkstra oracle first.
# Impact: guarded by the rust_equiv gate; 0-based ids (production 1-based edge
# lists convert before calling).
rust_dijkstra <- function(offsets, targets, weights, source) {
  if (!flows_rust_available()) return(NULL)
  n_nodes <- length(offsets) - 1L
  n_edges <- length(targets)
  if (n_nodes <= 0L) return(numeric(0))
  # Paired-length contract: the C side reads length(targets) doubles from
  # `weights` — a shorter weights vector would be an out-of-bounds read into
  # R heap memory. Validate here; fall back to R on any mismatch.
  if (length(weights) != n_edges) return(NULL)
  out <- tryCatch(
    .C("flows_dijkstra_c",
       offsets = as.integer(offsets), n_nodes = as.integer(n_nodes),
       targets = as.integer(targets), weights = as.double(weights),
       n_edges = as.integer(n_edges), source = as.integer(source),
       out = double(n_nodes), NAOK = TRUE)$out,
    error = function(e) NULL
  )
  # NaN is the Rust-side error sentinel (invalid ids/offsets, or a caught
  # panic): valid distances are finite or +Inf, never NaN. NULL -> R fallback.
  if (!is.null(out) && length(out) && anyNA(out)) return(NULL)
  out
}

# Why: the contraction-hierarchy router answers shortest-path COSTS far faster
# than a full Dijkstra once preprocessed — the CONUS "cross-country as fast as
# local" mechanism. This wrapper builds the CH once and answers a batch of
# (source, target) queries.
# What: given a 0-based CSR graph and equal-length 0-based `srcs`/`dsts` query
# vectors, returns the shortest-path cost per pair (Inf unreachable), or NULL if
# the Rust core is unavailable so callers fall back to R.
# How: .C() into flows_ch_query_c (preprocess once, answer all pairs).
# When: router cost queries; NOT yet wired into production route planning —
# proven against pure-R Dijkstra costs in the rust_equiv gate first.
# Impact: CH cost == Dijkstra cost (cargo-gated); guarded by rust_equiv.
rust_ch_query <- function(offsets, targets, weights, srcs, dsts) {
  if (!flows_rust_available()) return(NULL)
  n_nodes <- length(offsets) - 1L
  n_edges <- length(targets)
  nq <- length(srcs)
  if (n_nodes <= 0L || nq <= 0L) return(numeric(0))
  # Paired-length contracts: the C side reads length(srcs) ids from `dsts`
  # and length(targets) doubles from `weights` — shorter vectors would be
  # out-of-bounds reads into R heap memory. Validate; fall back to R.
  if (length(dsts) != nq || length(weights) != n_edges) return(NULL)
  out <- tryCatch(
    .C("flows_ch_query_c",
       offsets = as.integer(offsets), n_nodes = as.integer(n_nodes),
       targets = as.integer(targets), weights = as.double(weights), n_edges = as.integer(n_edges),
       srcs = as.integer(srcs), dsts = as.integer(dsts), n_queries = as.integer(nq),
       out = double(nq), NAOK = TRUE)$out,
    error = function(e) NULL
  )
  # NaN = Rust-side error sentinel (invalid ids/offsets or caught panic);
  # valid costs are finite or +Inf. NULL -> caller falls back to pure R.
  if (!is.null(out) && length(out) && anyNA(out)) return(NULL)
  out
}

# One-time load attempt at source time (fork-safe: before any mclapply).
invisible(flows_rust_try_load())
