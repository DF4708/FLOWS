# -----------------------------------------------------------------------------
# rust_integration_equiv.R — proves the OPTIONAL Rust core, when loaded via the
# R-side integration layer (R/rust_core.R), returns byte-identical results to
# the R implementations it would replace. Gate contract:
#   * Rust core present  -> compare rust_piecewise_score vs R; must be identical.
#   * Rust core absent    -> skip gracefully (still a pass), since the R path is
#                            the default and the dylib is optional (e.g. the
#                            mirror worker may not have built it).
# Usage:  Rscript tests/jobs/rust_integration_equiv.R
# -----------------------------------------------------------------------------

suppressWarnings(suppressMessages({
  # Minimal deps: canonical RISK constants (NOT a hardcoded copy — a copy here
  # would keep the gate green against stale values after a retune) + the R
  # oracle + the loader. Source in the same order global.R would.
  source("R/risk_constants.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
  safe_numeric <- function(x) suppressWarnings(as.numeric(x))
  source("R/rust_core.R", local = TRUE)
  source("R/scoring.R", local = TRUE)
}))

if (!flows_rust_available()) {
  cat("rust_equiv: skipped (Rust core dylib absent; R path is default) — PASS\n")
  quit(status = 0)
}

# Battery mirrors the real scoring thresholds + edge values. Oracle is the
# PURE-R _rimpl (never calls Rust) so the comparison is non-circular even though
# the public wrappers now dispatch to Rust.
thr <- list(c(25,75,150), c(15,28,45), c(25,50,75), c(3,6,9), c(2.5,4.0,5.5),
            c(0.25,1.0,2.5), c(1.5,6,15), c(85,95,105), c(8,20,35))
set.seed(17); mism <- 0L; total <- 0L
for (t in thr) {
  vals <- c(-1, 0, t[1], (t[1]+t[2])/2, t[2], (t[2]+t[3])/2, t[3], t[3]*2, t[3]*100,
            runif(600, -5, t[3]*3), NA, Inf, -Inf)
  r_ref  <- vector_piecewise_score_rowwise_rimpl(vals, t[1], t[2], t[3])       # pure R
  r_scal <- rust_piecewise_score(vals, t[1], t[2], t[3])                       # rust scalar
  r_row  <- rust_piecewise_score_rowwise(vals, t[1], t[2], t[3])               # rust rowwise (scalar thresholds recycle)
  # NULL here means a symbol is missing (stale/partial dylib, e.g. the mirror
  # between sync and its next cargo rebuild). Production falls back to R safely,
  # so this is NOT a divergence — skip the comparison rather than fail. Only a
  # non-NULL value MISMATCH is a real failure.
  if (!is.null(r_scal)) { total <- total + length(vals); mism <- mism + sum(!mapply(identical, r_ref, r_scal)) }
  if (!is.null(r_row))  { total <- total + length(vals); mism <- mism + sum(!mapply(identical, r_ref, r_row)) }
}
# Rowwise with genuinely PER-ELEMENT (spatially-varying) thresholds — the hot path.
set.seed(29)
for (i in 1:40) {
  n <- sample(5:80, 1)
  v <- c(runif(n, -5, 200)); lo <- runif(n, 5, 45); mi <- runif(n, 50, 95); hi <- runif(n, 100, 170)
  if (i %% 3 == 0) v[sample(n, 1)] <- NA
  if (i %% 4 == 0) lo[sample(n, 1)] <- NA
  a <- vector_piecewise_score_rowwise_rimpl(v, lo, mi, hi)
  b <- rust_piecewise_score_rowwise(v, lo, mi, hi)
  if (!is.null(b)) { total <- total + length(v); mism <- mism + sum(!mapply(identical, a, b)) }  # NULL = stale dylib, skip
}

# --- CONUS router ingest: Rust CsrGraph Dijkstra vs pure-R Dijkstra oracle ---
# 0-based CSR; ties settle to lowest node id (matches routing.rs HeapItem Ord).
r_dijkstra <- function(offsets, targets, weights, source) {
  n <- length(offsets) - 1L
  dist <- rep(Inf, n); dist[source + 1L] <- 0; done <- rep(FALSE, n)
  repeat {
    cand <- which(!done & is.finite(dist)); if (length(cand) == 0L) break
    u0 <- cand[which.min(dist[cand])] - 1L
    done[u0 + 1L] <- TRUE
    lo <- offsets[u0 + 1L]; hi <- offsets[u0 + 2L] - 1L
    if (hi >= lo) for (k0 in lo:hi) {
      v0 <- targets[k0 + 1L]; nd <- dist[u0 + 1L] + weights[k0 + 1L]
      if (nd < dist[v0 + 1L]) dist[v0 + 1L] <- nd
    }
  }
  dist
}
set.seed(21)
for (t in 1:60) {
  n <- sample(3:40, 1); offs <- 0L; tgt <- integer(0); wt <- numeric(0)
  for (u in 1:n) {
    deg <- sample(0:4, 1)
    if (deg > 0) { tgt <- c(tgt, sample(0:(n - 1), deg, replace = TRUE)); wt <- c(wt, round(runif(deg, 0.1, 50), 3)) }
    offs <- c(offs, length(tgt))
  }
  s <- sample(0:(n - 1), 1)
  rd <- rust_dijkstra(offs, tgt, wt, s)
  if (!is.null(rd)) { total <- total + n; mism <- mism + sum(!mapply(identical, r_dijkstra(offs, tgt, wt, s), rd)) }
}

# --- CONUS router CH: rust_ch_query costs vs pure-R Dijkstra, on UNDIRECTED
# graphs (CH treats the graph undirected, matching the bidirectional road
# graph). NOTE: CH is NOT bit-identical to Dijkstra — shortcuts pre-sum path
# segments, so float addition order differs; costs are equal within rounding.
# So this check uses a tolerance (<1e-9), unlike the byte-identical scoring
# checks above. Counted separately as ch_bad (a real failure only if a cost
# differs by more than rounding). ---
ch_total <- 0L; ch_bad <- 0L; ch_worst <- 0
build_undirected <- function(n, ea, eb, ew) {
  al <- vector("list", n); wl <- vector("list", n)
  for (i in seq_along(ea)) {
    a <- ea[i]; b <- eb[i]; w <- ew[i]
    al[[a + 1L]] <- c(al[[a + 1L]], b); wl[[a + 1L]] <- c(wl[[a + 1L]], w)
    al[[b + 1L]] <- c(al[[b + 1L]], a); wl[[b + 1L]] <- c(wl[[b + 1L]], w)
  }
  offs <- 0L; tg <- integer(0); wt <- numeric(0)
  for (u in 1:n) { tg <- c(tg, al[[u]]); wt <- c(wt, wl[[u]]); offs <- c(offs, length(tg)) }
  list(offsets = offs, targets = tg, weights = wt)
}
set.seed(2026)
for (t in 1:50) {
  n <- sample(4:40, 1); m <- sample(n:(2 * n), 1)
  ea <- sample(0:(n - 1), m, TRUE); eb <- sample(0:(n - 1), m, TRUE); ew <- round(runif(m, 0.1, 50), 3)
  keep <- ea != eb; ea <- ea[keep]; eb <- eb[keep]; ew <- ew[keep]
  if (length(ea) == 0) next
  g <- build_undirected(n, ea, eb, ew)
  nq <- 5; ss <- sample(0:(n - 1), nq, TRUE); dd <- sample(0:(n - 1), nq, TRUE)
  chq <- rust_ch_query(g$offsets, g$targets, g$weights, ss, dd)
  if (is.null(chq)) next  # core stale, skip
  ref <- vapply(seq_len(nq), function(i) r_dijkstra(g$offsets, g$targets, g$weights, ss[i])[dd[i] + 1L], numeric(1))
  d <- abs(chq - ref); d[is.infinite(chq) & is.infinite(ref)] <- 0
  ch_total <- ch_total + nq
  ch_bad <- ch_bad + sum(d > 1e-9, na.rm = TRUE)
  ch_worst <- max(ch_worst, max(d[is.finite(d)], 0))
}
if (mism > 0L || ch_bad > 0L) {
  cat(sprintf("rust_equiv: FAIL — scoring/dijkstra byte-mismatch=%d, CH cost-diff>1e-9=%d (worst %.1e)\n",
              mism, ch_bad, ch_worst))
  quit(status = 1)
}
cat(sprintf("rust_equiv: %d/%d byte-identical (0 mismatch) | CH cost-equal %d/%d within 1e-9 (worst %.1e) — core %s\n",
            total, total, ch_total, ch_total, ch_worst, .flows_rust_state$path))
