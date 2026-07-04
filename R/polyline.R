# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/polyline.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: routing providers (Google/HERE/etc.) return polylines as the compact
# Google encoded-polyline string, but our map layer needs lon/lat coordinates.
# What: returns a numeric [n,2] matrix with columns "lon"/"lat" (empty matrix
# if encoded is empty or malformed).
# How: implements the standard varint-with-zigzag decoder, accumulating signed
# lat/lon deltas scaled by 1e-5.
# When: called for each route or alert geometry that arrives as an encoded
# polyline before being wrapped into an sf linestring.
# Impact: a bug in shift/accumulator math would offset every coordinate; the
# returned matrix is the geometric ground truth for the rest of the pipeline.
decode_polyline_matrix <- function(encoded) {
  # In-house decoder, overflow-safe by construction: each varint accumulates in
  # DOUBLE space (exact up to 2^53; a valid delta needs <= 32 bits, so there is
  # ~21 bits of headroom) instead of R's 32-bit signed integers, where the old
  # `-bitwShiftR(result, 1L) - 1L` un-zigzag underflowed to NA_integer_ on
  # malformed/overlong varints ("NAs produced by integer overflow").
  # Vectorized: one utf8ToInt pass + rowsum, no per-character substr loop.
  # Semantics preserved from the loop version: a truncated trailing varint (or
  # a dangling lat with no lon) is dropped; a varint longer than MAX_CHUNKS is
  # malformed and decoding stops at it, returning the pairs decoded so far.
  empty <- matrix(numeric(0), ncol = 2, dimnames = list(NULL, c("lon", "lat")))
  encoded <- safe_string(encoded)
  if (!nzchar(encoded)) return(empty)

  b <- utf8ToInt(encoded) - 63L
  cont <- b >= 0x20L                       # continuation bit (bit 5)
  ends <- which(!cont)                     # last chunk of each complete varint
  if (length(ends) == 0L) return(empty)    # no complete varint at all
  n_used <- ends[length(ends)]             # chars past the last end are a
  b <- b[seq_len(n_used)]                  # truncated varint -> dropped

  starts <- c(1L, ends[-length(ends)] + 1L)
  lens <- ends - starts + 1L
  MAX_CHUNKS <- 10L                        # 50 bits; valid deltas need <= 7
  bad <- which(lens > MAX_CHUNKS)
  if (length(bad) > 0L) {                  # malformed: stop before first bad varint
    keep <- bad[1L] - 1L
    if (keep == 0L) return(empty)
    ends <- ends[seq_len(keep)]
    starts <- starts[seq_len(keep)]
    n_used <- ends[keep]
    b <- b[seq_len(n_used)]
  }

  group <- rep.int(seq_along(ends), ends - starts + 1L)
  offset <- seq_len(n_used) - starts[group]          # chunk position in varint
  # (b %% 32) == two's-complement bitwAnd(b, 0x1f) even for negative b (chars
  # below '?'); 32^offset keeps every term exact in double space.
  vals <- rowsum((b %% 32L) * 32^offset, group, reorder = FALSE)[, 1L]

  odd <- vals %% 2 == 1
  deltas <- ifelse(odd, -(vals + 1) / 2, vals / 2)   # un-zigzag, exact in double

  n_pairs <- length(deltas) %/% 2L
  if (n_pairs == 0L) return(empty)
  dlat <- deltas[seq.int(1L, by = 2L, length.out = n_pairs)]
  dlon <- deltas[seq.int(2L, by = 2L, length.out = n_pairs)]
  out <- cbind(lon = cumsum(dlon) / 1e5, lat = cumsum(dlat) / 1e5)
  rownames(out) <- NULL
  out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Wraps a [n,2] lon/lat matrix into a CRS-4326 sf linestring sfc,
# returning an empty geometrycollection if too few points.
# How: sf geometry op.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
linestring_sfc_from_matrix <- function(mat) {
  if (is.null(mat) || length(mat) == 0 || nrow(mat) < 2) {
    return(sf::st_sfc(sf::st_geometrycollection(), crs = 4326))
  }
  sf::st_sfc(sf::st_linestring(as.matrix(mat[, c("lon", "lat"), drop = FALSE])), crs = 4326)
}

