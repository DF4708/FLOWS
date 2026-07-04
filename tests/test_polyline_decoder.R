# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# tests/test_polyline_decoder.R — regression gate for the in-house polyline
# decoder rewrite (R/polyline.R).
#
# Contract being enforced:
#   1. BYTE-IDENTICAL to the previous implementation for every VALID encoded
#      polyline (identical(), not tolerance).
#   2. No "NAs produced by integer overflow" warning and no NA coordinates on
#      malformed/overlong varints (the old decoder's latent bug at bit 31).
#   3. Truncation semantics preserved: incomplete trailing varint / dangling
#      lat-without-lon are dropped, earlier pairs still returned.
#
# Run: Rscript tests/test_polyline_decoder.R   (exits non-zero on failure)

suppressWarnings(suppressMessages({
  source("R/util.R")
  source("R/polyline.R")
}))

fail <- function(...) { cat("FAIL:", sprintf(...), "\n"); quit(status = 1L) }
pass_n <- 0L
ok <- function(label) { pass_n <<- pass_n + 1L; cat(sprintf("  ok %2d — %s\n", pass_n, label)) }

# --- verbatim copy of the OLD implementation (pre-rewrite reference) ---------
decode_polyline_matrix_old <- function(encoded) {
  encoded <- safe_string(encoded)
  if (!nzchar(encoded)) return(matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat"))))
  index <- 1L
  lat <- 0L
  lon <- 0L
  len <- nchar(encoded)
  coords <- vector("list", 0)

  decode_value <- function() {
    result <- 0L
    shift <- 0L
    repeat {
      if (index > len) return(NULL)
      b <- utf8ToInt(substr(encoded, index, index)) - 63L
      index <<- index + 1L
      result <- bitwOr(result, bitwShiftL(bitwAnd(b, 0x1fL), shift))
      shift <- shift + 5L
      if (b < 0x20L) break
    }
    if (bitwAnd(result, 1L) != 0L) {
      -bitwShiftR(result, 1L) - 1L
    } else {
      bitwShiftR(result, 1L)
    }
  }

  repeat {
    dlat <- decode_value()
    if (is.null(dlat)) break
    dlon <- decode_value()
    if (is.null(dlon)) break
    lat <- lat + dlat
    lon <- lon + dlon
    coords[[length(coords) + 1L]] <- c(lon / 1e5, lat / 1e5)
  }

  if (length(coords) == 0) return(matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat"))))
  out <- do.call(rbind, coords)
  colnames(out) <- c("lon", "lat")
  out
}

# --- reference encoder (Google encoded-polyline spec) -------------------------
encode_polyline <- function(latlon) {
  encode_value <- function(v) {
    zig <- if (v < 0) -2 * v - 1 else 2 * v
    chars <- integer(0)
    repeat {
      chunk <- zig %% 32
      zig <- zig %/% 32
      if (zig > 0) chunk <- chunk + 32
      chars <- c(chars, chunk + 63)
      if (zig == 0) break
    }
    intToUtf8(chars)
  }
  prev_lat <- 0; prev_lon <- 0; out <- character(0)
  for (i in seq_len(nrow(latlon))) {
    ilat <- round(latlon[i, 1] * 1e5); ilon <- round(latlon[i, 2] * 1e5)
    out <- c(out, encode_value(ilat - prev_lat), encode_value(ilon - prev_lon))
    prev_lat <- ilat; prev_lon <- ilon
  }
  paste(out, collapse = "")
}

# --- 1. byte-identical corpus: old vs new on valid polylines ------------------
set.seed(4708)
n_cases <- 500L
for (case in seq_len(n_cases)) {
  n_pts <- sample(1:40, 1L)
  lat <- cumsum(c(runif(1, -90, 90),  runif(n_pts - 1L, -0.5, 0.5)))
  lon <- cumsum(c(runif(1, -180, 180), runif(n_pts - 1L, -0.5, 0.5)))
  lat <- pmax(pmin(lat, 90), -90); lon <- pmax(pmin(lon, 180), -180)
  enc <- encode_polyline(cbind(lat, lon))
  a <- decode_polyline_matrix_old(enc)
  b <- decode_polyline_matrix(enc)
  if (!identical(a, b)) {
    fail("corpus case %d not byte-identical (n_pts=%d, enc=%s)", case, n_pts, substr(enc, 1, 60))
  }
}
ok(sprintf("byte-identical to old decoder on %d random valid polylines", n_cases))

# Extremes: corner coordinates, zero deltas, repeated points, single point.
extremes <- list(
  cbind(c(90, -90, 90), c(180, -180, 180)),
  cbind(c(0, 0, 0), c(0, 0, 0)),
  cbind(44.5, -89.5),
  cbind(c(38.5, 40.7, 43.252), c(-120.2, -120.95, -126.453))
)
for (m in extremes) {
  enc <- encode_polyline(m)
  if (!identical(decode_polyline_matrix_old(enc), decode_polyline_matrix(enc))) {
    fail("extreme case not byte-identical: %s", enc)
  }
}
ok("byte-identical on extreme/degenerate coordinates")

# Google's documented reference vector.
g <- decode_polyline_matrix("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
g_expect <- cbind(lon = c(-12020000, -12095000, -12645300) / 1e5,
                  lat = c(3850000, 4070000, 4325200) / 1e5)
if (!identical(g, g_expect)) fail("Google reference vector mismatch")
ok("Google spec reference vector decodes exactly")

# --- 2. overflow regression: malformed input, no warning, no NA ---------------
# 7-chunk varint with bit 31 set: old decoder warned "NAs produced by integer
# overflow" and emitted NA; new decoder must be silent and finite.
overflow_enc <- paste0(strrep("~", 6), "^", strrep("~", 6), "^")
w <- NULL
res <- withCallingHandlers(
  decode_polyline_matrix(overflow_enc),
  warning = function(cond) { w <<- conditionMessage(cond); invokeRestart("muffleWarning") }
)
if (!is.null(w)) fail("malformed input still warns: %s", w)
if (anyNA(res)) fail("malformed input still produces NA coordinates")
ok("bit-31 overflow input: no warning, no NA (old bug fixed)")

# Confirm the old decoder DID fail on this input (guards against a vacuous test).
old_warned <- FALSE
invisible(withCallingHandlers(
  decode_polyline_matrix_old(overflow_enc),
  warning = function(cond) { old_warned <<- TRUE; invokeRestart("muffleWarning") }
))
if (!old_warned) fail("sanity: old decoder no longer reproduces the overflow warning")
ok("sanity: old decoder reproduces the overflow warning on the same input")

# Overlong varint (> 10 chunks) = malformed: decoding stops there, prior pairs kept.
valid_prefix <- encode_polyline(cbind(43.07, -89.40))
mal <- paste0(valid_prefix, strrep("~", 15), "^")
res <- decode_polyline_matrix(mal)
if (!identical(res, decode_polyline_matrix(valid_prefix))) {
  fail("overlong varint did not stop cleanly at the malformed point")
}
ok("overlong varint: stops at malformed varint, keeps prior pairs")

# --- 3. truncation / degenerate-input semantics -------------------------------
full <- encode_polyline(cbind(c(43.07, 43.10), c(-89.40, -89.35)))
truncated <- substr(full, 1, nchar(full) - 1L)  # cut mid-varint
if (!identical(decode_polyline_matrix_old(truncated), decode_polyline_matrix(truncated))) {
  fail("truncated input not byte-identical to old semantics")
}
ok("truncated trailing varint: identical drop semantics")

dangling <- encode_polyline(cbind(43.07, -89.40))
dangling <- paste0(dangling, substr(encode_polyline(cbind(1, 1)), 1, 2))  # lat w/o lon
if (!identical(decode_polyline_matrix_old(dangling), decode_polyline_matrix(dangling))) {
  fail("dangling lat-without-lon not byte-identical to old semantics")
}
ok("dangling lat without lon: identical drop semantics")

empty_expect <- matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat")))
for (bad in list("", NULL, NA_character_)) {
  if (!identical(decode_polyline_matrix(bad), empty_expect)) fail("degenerate input != empty matrix")
}
ok("empty/NULL/NA input returns the canonical empty matrix")

cat(sprintf("\nPASS: polyline decoder gate — %d checks green.\n", pass_n))
