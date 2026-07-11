# -----------------------------------------------------------------------------
# dep_reduction_equiv.R — proves FLOWS' in-house replacements for external
# dependencies are byte-identical to the library functions they replace.
# Dependency-reduction SOP: own the tool, but only after this gate is green.
#
# Currently covers: flows_bind_rows vs dplyr::bind_rows.
# Usage:  Rscript tests/jobs/dep_reduction_equiv.R
# -----------------------------------------------------------------------------

suppressWarnings(suppressMessages({
  source("R/util.R", chdir = FALSE)
}))
have_dplyr <- requireNamespace("dplyr", quietly = TRUE)

# Compare normalised to plain data.frame: dplyr::bind_rows returns a tibble,
# our callers consume it as a data.frame (directly or via st_sf), so the
# meaningful equality is of the data content + column order + types.
norm <- function(x) {
  x <- as.data.frame(x, stringsAsFactors = FALSE)
  rownames(x) <- NULL
  x
}

# Input shapes FLOWS actually passes to bind_rows: lists of single-/multi-row
# data.frames with consistent columns; NULLs; zero-row frames; mixed numeric/
# character/logical; the union-of-columns case; the empty list.
cases <- list(
  homogeneous_single = list(
    data.frame(a = 1L, b = "x", stringsAsFactors = FALSE),
    data.frame(a = 2L, b = "y", stringsAsFactors = FALSE),
    data.frame(a = 3L, b = "z", stringsAsFactors = FALSE)
  ),
  homogeneous_multi = list(
    data.frame(id = 1:3, v = c(1.5, 2.5, 3.5)),
    data.frame(id = 4:5, v = c(4.5, 5.5))
  ),
  with_nulls = list(
    data.frame(a = 1L, b = "x", stringsAsFactors = FALSE),
    NULL,
    data.frame(a = 2L, b = "y", stringsAsFactors = FALSE)
  ),
  with_zero_row = list(
    data.frame(a = integer(0), b = character(0), stringsAsFactors = FALSE),
    data.frame(a = 1L, b = "x", stringsAsFactors = FALSE)
  ),
  # Regression: a ZERO-row frame that is MISSING a union column — the old
  # `d[[m]] <- NA` errored here ("replacement has 1 row, data has 0") where
  # dplyr succeeded.
  zero_row_union = list(
    data.frame(a = integer(0), stringsAsFactors = FALSE),
    data.frame(a = 1L, b = "x", stringsAsFactors = FALSE)
  ),
  mixed_types = list(
    data.frame(n = 1.0, s = "a", flag = TRUE, stringsAsFactors = FALSE),
    data.frame(n = 2.0, s = "b", flag = FALSE, stringsAsFactors = FALSE)
  ),
  union_columns = list(
    data.frame(a = 1L, b = "x", stringsAsFactors = FALSE),
    data.frame(a = 2L, c = 9.9, stringsAsFactors = FALSE)
  ),
  na_and_numbers = list(
    data.frame(x = c(1.1, NA, 3.3), y = c("p", "q", NA), stringsAsFactors = FALSE),
    data.frame(x = 4.4, y = "r", stringsAsFactors = FALSE)
  ),
  single_element = list(
    data.frame(only = 1:4, lab = letters[1:4], stringsAsFactors = FALSE)
  )
)

pass <- 0L; fail <- 0L; notes <- character(0)
# List form: flows_bind_rows(list) vs dplyr::bind_rows(list).
for (nm in names(cases)) {
  x <- cases[[nm]]
  ours <- tryCatch(norm(flows_bind_rows(x)), error = function(e) structure("ERR", msg = conditionMessage(e)))
  if (!have_dplyr) { notes <- c(notes, sprintf("%-20s ours-only (dplyr absent): %d rows", nm, nrow(ours))); next }
  ref <- tryCatch(norm(dplyr::bind_rows(x)), error = function(e) structure("ERR", msg = conditionMessage(e)))
  if (identical(ours, ref)) { pass <- pass + 1L } else {
    fail <- fail + 1L
    notes <- c(notes, sprintf("MISMATCH list:%s", nm))
  }
}
# Multi-arg form: flows_bind_rows(a, b, c) vs dplyr::bind_rows(a, b, c) — the
# route.R:1225/1264 shape (splice three frames incl a zero-row slice).
if (have_dplyr) {
  a <- data.frame(instruction = "Start", miles = 0.0, stringsAsFactors = FALSE)
  b <- data.frame(instruction = "Continue through 5 steps", miles = 12.3, stringsAsFactors = FALSE)
  cc <- data.frame(instruction = c("Turn", "Arrive"), miles = c(1.1, 0.0), stringsAsFactors = FALSE)
  multi <- list(
    three_args      = list(a, b, cc),
    with_zero_slice = list(a[0, , drop = FALSE], b, cc),
    two_args        = list(a, cc)
  )
  for (nm in names(multi)) {
    args <- multi[[nm]]
    ours <- tryCatch(norm(do.call(flows_bind_rows, args)), error = function(e) structure("ERR", msg = conditionMessage(e)))
    ref  <- tryCatch(norm(do.call(dplyr::bind_rows, args)), error = function(e) structure("ERR", msg = conditionMessage(e)))
    if (identical(ours, ref)) { pass <- pass + 1L } else {
      fail <- fail + 1L; notes <- c(notes, sprintf("MISMATCH multi:%s", nm))
    }
  }
}

cat(sprintf("flows_bind_rows vs dplyr::bind_rows: %d/%d byte-identical (%d fail)\n",
            pass, pass + fail, fail))

# ---- flows_group_aggregate vs dplyr::group_by |> summarise ----
gpass <- 0L; gfail <- 0L
if (have_dplyr) {
  # Site 1 shape (global.R): group by numeric lat_band -> mean lon/lat + first zip.
  set.seed(11)
  z1 <- data.frame(
    lat_band = sample(c(43.5, 44.0, 45.25, 46.1), 60, TRUE),
    center_lon = runif(60, -92, -87), center_lat = runif(60, 42, 47),
    zipcode = sprintf("5%04d", sample(1000:9999, 60)), stringsAsFactors = FALSE
  )
  ours1 <- norm(flows_group_aggregate(z1, "lat_band", list(
    rep_lon = function(d) mean(d$center_lon, na.rm = TRUE),
    rep_lat = function(d) mean(d$center_lat, na.rm = TRUE),
    rep_zip = function(d) d$zipcode[1L])))
  ref1 <- norm(dplyr::summarise(dplyr::group_by(z1, lat_band),
    rep_lon = mean(center_lon, na.rm = TRUE), rep_lat = mean(center_lat, na.rm = TRUE),
    rep_zip = dplyr::first(zipcode), .groups = "drop"))
  if (identical(ours1, ref1)) gpass <- gpass + 1L else { gfail <- gfail + 1L; cat("MISMATCH group:lat_band\n") }

  # Site 2 shape (wi_loaders.R): group by (road_id, zipcode) -> sum length.
  set.seed(12)
  z2 <- data.frame(
    road_id = sprintf("w%d", sample(1:15, 200, TRUE)),
    zipcode = sprintf("5%04d", sample(3000:3010, 200, TRUE)),
    piece_length_m = runif(200, 1, 5000), stringsAsFactors = FALSE
  )
  ours2 <- norm(flows_group_aggregate(z2, c("road_id", "zipcode"), list(
    length_m = function(d) sum(d$piece_length_m, na.rm = TRUE))))
  ref2 <- norm(dplyr::summarise(dplyr::group_by(z2, road_id, zipcode),
    length_m = sum(piece_length_m, na.rm = TRUE), .groups = "drop"))
  if (identical(ours2, ref2)) gpass <- gpass + 1L else { gfail <- gfail + 1L; cat("MISMATCH group:road_zip\n") }
  cat(sprintf("flows_group_aggregate vs dplyr group_by|>summarise: %d/%d byte-identical (%d fail)\n",
              gpass, gpass + gfail, gfail))
}
if (fail > 0 || gfail > 0) quit(status = 1)
