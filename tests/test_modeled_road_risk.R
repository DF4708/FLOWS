suppressMessages({
  source("R/util.R")
  source("R/route.R")
})

# Replicate the original (pre-vectorisation) function inline to compare.
build_modeled_road_risk_index_OLD <- function(roads, lookup, zips, length_lookup) {
  if (is.null(roads) || nrow(roads) == 0 || is.null(zips) || nrow(zips) == 0) {
    return(data.frame(
      road_id = character(0), driving_total_risk = numeric(0),
      driving_reason_text = character(0), dominant_zip = character(0),
      road_source = character(0), official_cause_text = character(0),
      stringsAsFactors = FALSE
    ))
  }
  zip_drive <- stats::setNames(suppressWarnings(as.numeric(zips$driving_total_risk %||% rep(0, nrow(zips)))), zips$zipcode)
  zip_drive[!is.finite(zip_drive)] <- 0
  zip_reason <- stats::setNames(as.character(zips$driving_reason_text %||% rep("", nrow(zips))), zips$zipcode)
  zip_transport_reason <- stats::setNames(as.character(zips$wi511_transport_reason %||% rep("", nrow(zips))), zips$zipcode)
  road_ids <- as.character(roads$road_id %||% rep("", nrow(roads)))
  n_roads <- length(road_ids)
  if (!is.null(length_lookup) && length(length_lookup) == 0) length_lookup <- NULL
  lookup_subset <- lookup[road_ids]
  length_lookup_subset <- if (!is.null(length_lookup)) length_lookup[road_ids] else NULL
  road_susceptibility <- suppressWarnings(as.numeric(roads$susceptibility %||% rep(1, n_roads)))
  road_susceptibility[!is.finite(road_susceptibility)] <- 1
  dominant_zip <- vapply(seq_len(n_roads), function(i) {
    z <- lookup_subset[[i]] %||% character(0)
    if (length(z) == 0) return(NA_character_)
    vals <- zip_drive[z]
    if (length(vals) == 0 || all(!is.finite(vals))) return(NA_character_)
    z[which.max(ifelse(is.finite(vals), vals, -Inf))][1]
  }, character(1))
  driving_total_risk <- vapply(seq_len(n_roads), function(i) {
    z <- lookup_subset[[i]] %||% character(0)
    vals <- zip_drive[z]
    vals <- vals[is.finite(vals)]
    if (length(vals) == 0) return(0)
    road_mult <- 0.85 + 0.15 * road_susceptibility[i]
    if (!is.null(length_lookup_subset)) {
      lens_named <- length_lookup_subset[[i]]
      if (!is.null(lens_named) && length(lens_named) > 0) {
        lens <- suppressWarnings(as.numeric(lens_named[names(vals)]))
        lens[!is.finite(lens) | lens < 0] <- 0
        total_len <- sum(lens, na.rm = TRUE)
        if (total_len > 0) {
          weighted <- sum(vals * lens, na.rm = TRUE) / total_len
          return(pmin(1, weighted * road_mult))
        }
      }
    }
    pmin(1, max(vals, na.rm = TRUE) * road_mult)
  }, numeric(1))
  is_blank_zip <- function(z) is.null(z) || length(z) == 0L || is.na(z) || !nzchar(as.character(z))
  safe_lookup <- function(tbl, key) {
    if (is_blank_zip(key)) return(NA_character_)
    val <- tbl[as.character(key)]
    if (is.na(val) || is.null(val)) return(NA_character_)
    as.character(val)
  }
  driving_reason_text <- vapply(seq_len(n_roads), function(i) {
    z <- lookup_subset[[i]] %||% character(0)
    vals <- zip_drive[z]
    if (length(z) == 0 || all(!is.finite(vals))) return("All clear.")
    best_zip <- z[which.max(ifelse(is.finite(vals), vals, -Inf))][1]
    reason <- safe_lookup(zip_reason, best_zip)
    if (!is.na(reason) && nzchar(reason)) return(reason)
    transport <- safe_lookup(zip_transport_reason, best_zip)
    if (!is.na(transport) && nzchar(transport)) return(transport)
    "All clear."
  }, character(1))
  road_source <- vapply(dominant_zip, function(best_zip) {
    if (is_blank_zip(best_zip)) return("Modeled ZIP risk")
    transport <- safe_lookup(zip_transport_reason, best_zip)
    if (!is.na(transport) && nzchar(trimws(transport))) {
      "Modeled ZIP risk + 511 ZIP transport signal"
    } else {
      "Modeled ZIP risk"
    }
  }, character(1))
  official_cause_text <- vapply(dominant_zip, function(best_zip) {
    if (is_blank_zip(best_zip)) return("none")
    transport <- safe_lookup(zip_transport_reason, best_zip)
    classify_official_transport_cause(if (is.na(transport)) "" else transport, "511 ZIP transport")
  }, character(1))
  data.frame(
    road_id = road_ids, driving_total_risk = driving_total_risk,
    driving_reason_text = driving_reason_text, dominant_zip = dominant_zip,
    road_source = road_source, official_cause_text = official_cause_text,
    stringsAsFactors = FALSE
  )
}

set.seed(42)
zips_df <- data.frame(
  zipcode = sprintf("5%04d", 1:50),
  driving_total_risk = c(runif(45), NA, NaN, 0.99, 0, 0.5),
  driving_reason_text = c(rep("Slick: snow icing.", 10), rep("", 5), rep("Closure on US-12.", 10), rep("Crash near downtown.", 10), rep("", 15)),
  wi511_transport_reason = c(rep("", 25), rep("WINTER WEATHER ADVISORY", 10), rep("ROAD CLOSED CRASH", 10), rep("", 5)),
  stringsAsFactors = FALSE
)
n_test_roads <- 1500
road_ids <- sprintf("r%05d", seq_len(n_test_roads))
roads_df <- data.frame(road_id = road_ids, susceptibility = runif(n_test_roads, 0.5, 1.5), stringsAsFactors = FALSE)

# Build lookup using `[name]` assignment so list shape stays intact.
lookup <- vector("list", n_test_roads); names(lookup) <- road_ids
length_lookup <- vector("list", n_test_roads); names(length_lookup) <- road_ids
for (i in seq_len(n_test_roads)) {
  rid <- road_ids[i]
  k <- sample(c(0L, 1L, 2L, 3L, 5L), 1, prob = c(0.05, 0.4, 0.3, 0.15, 0.1))
  if (k == 0L) {
    lookup[[rid]] <- character(0); length_lookup[[rid]] <- numeric(0); next
  }
  use_missing <- runif(1) < 0.1
  zips <- sample(zips_df$zipcode, k)
  if (use_missing) zips <- c(zips, "99999")
  lookup[[rid]] <- zips
  if (runif(1) < 0.05) {
    length_lookup[[rid]] <- NULL
  } else if (runif(1) < 0.05) {
    length_lookup[[rid]] <- setNames(rep(0, length(zips)), zips)
  } else {
    ln <- runif(length(zips), 0, 5000)
    if (runif(1) < 0.05) ln[1] <- -1
    if (runif(1) < 0.05) ln[length(ln)] <- NaN
    length_lookup[[rid]] <- setNames(ln, zips)
  }
}

# 5% of roads have NO entry at all in either lookup. We do that by removing
# their names from each list (simulating lookup[road_id] returning NULL).
missing_idx <- sample(seq_len(n_test_roads), as.integer(n_test_roads * 0.05))
for (i in missing_idx) {
  lookup[[road_ids[i]]] <- NULL
  length_lookup[[road_ids[i]]] <- NULL
}

# (moved below source)

source("R/wi_loaders.R")
load_road_zip_length_lookup <- function() length_lookup

result_old <- build_modeled_road_risk_index_OLD(roads_df, lookup, zips_df, length_lookup)
result_new <- build_modeled_road_risk_index(roads_df, lookup, zips_df)

cat("Same nrow:", nrow(result_old) == nrow(result_new), "\n")
cat("Same road_id:", identical(result_old$road_id, result_new$road_id), "\n")

nr_max_diff <- max(abs(result_old$driving_total_risk - result_new$driving_total_risk), na.rm = TRUE)
cat("Max abs diff driving_total_risk:", nr_max_diff, "\n")

chr_cols <- c("driving_reason_text", "dominant_zip", "road_source", "official_cause_text")
for (col in chr_cols) {
  ov <- result_old[[col]]; nv <- result_new[[col]]
  ok <- identical(ov, nv)
  if (!ok) {
    diffs <- which(ov != nv | is.na(ov) != is.na(nv))
    cat("Column", col, "DIFFERS in", length(diffs), "rows\n")
    if (length(diffs) > 0) {
      for (j in head(diffs, 3)) {
        cat("  ", result_old$road_id[j], " old=[", ov[j], "] new=[", nv[j], "]\n")
      }
    }
  } else {
    cat("Column", col, "matches OK\n")
  }
}

cat("\n--- Edge cases ---\n")
empty_zips <- zips_df[0, ]
e1 <- build_modeled_road_risk_index(roads_df, lookup, empty_zips)
cat("Empty zips nrow:", nrow(e1), "\n")
empty_roads <- roads_df[0, ]
e2 <- build_modeled_road_risk_index(empty_roads, lookup, zips_df)
cat("Empty roads nrow:", nrow(e2), "\n")
empty_lookup <- vector("list", 5); names(empty_lookup) <- sprintf("r%05d", 1:5)
roads_small <- data.frame(road_id = names(empty_lookup), susceptibility = 1, stringsAsFactors = FALSE)
load_road_zip_length_lookup <- function() NULL
e3 <- build_modeled_road_risk_index(roads_small, empty_lookup, zips_df)
cat("All-empty lookup result risk values:", paste(e3$driving_total_risk, collapse = ","), "\n")
cat("All-empty lookup result reasons:    ", paste(unique(e3$driving_reason_text), collapse = " | "), "\n")

load_road_zip_length_lookup <- function() length_lookup
t_old <- system.time(for (i in 1:5) build_modeled_road_risk_index_OLD(roads_df, lookup, zips_df, length_lookup))
t_new <- system.time(for (i in 1:5) build_modeled_road_risk_index(roads_df, lookup, zips_df))
cat("\nTiming over 5 runs (1500 roads):\n  old:", t_old[3], "s\n  new:", t_new[3], "s\n  speedup:", round(t_old[3] / max(t_new[3], 0.001), 1), "x\n")
