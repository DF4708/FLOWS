# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/forecast.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Discretises lat into 1..n_bands bins between south and north using
# cut() - used to group ZIPs into latitude tiers for forecast caching.
# How: sf geometry op + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
assign_lat_band <- function(lat, south, north, n_bands = 10L) {
  breaks <- seq(south, north, length.out = n_bands + 1L)
  as.integer(cut(lat, breaks = breaks, include.lowest = TRUE, labels = FALSE))
}

# Why: forecasts are expensive per request, so we group ZCTAs into k-means
# regions and fetch a single forecast per region rather than per-ZIP.
# What: returns a list(assignments, reps) where assignments[i] is the
# region id for ZCTA i and reps holds region->representative_zip metadata.
# How: projects centroids to EPSG:5070, runs stats::kmeans with a fixed
# seed and centers = min(n_regions, n), and picks the row closest to each
# cluster center as the representative.
# When: called once on startup to materialise wi_zctas$forecast_region;
# downstream forecast helpers join through that field.
# Impact: a different seed or n_regions value reshuffles cache hits and
# changes the regional smoothing of the temperature/wind/pop layers.
build_forecast_region_context <- function(zctas, n_regions = FORECAST_REGION_COUNT) {
  n_regions <- max(1L, suppressWarnings(as.integer(n_regions %||% 1L)))
  if (is.null(zctas) || nrow(zctas) == 0) {
    return(list(
      assignments = integer(0),
      reps = data.frame(
        forecast_region = integer(0),
        rep_lon = numeric(0),
        rep_lat = numeric(0),
        rep_zip = character(0),
        stringsAsFactors = FALSE
      )
    ))
  }
  pts_proj <- safely(suppressWarnings(sf::st_transform(point_on_surface_lonlat(zctas), 5070)))
  coords <- safely(suppressWarnings(sf::st_coordinates(pts_proj)))
  if (is.null(coords) || nrow(coords) != nrow(zctas) || nrow(coords) == 0) {
    return(list(
      assignments = rep(1L, nrow(zctas)),
      reps = data.frame(
        forecast_region = 1L,
        rep_lon = zctas$center_lon[1],
        rep_lat = zctas$center_lat[1],
        rep_zip = as.character(zctas$zipcode[1]),
        stringsAsFactors = FALSE
      )
    ))
  }
  centers <- min(n_regions, nrow(coords))
  set.seed(5500L)
  km <- safely(stats::kmeans(coords, centers = centers, iter.max = 50))
  if (is.null(km)) {
    return(list(
      assignments = rep(1L, nrow(zctas)),
      reps = data.frame(
        forecast_region = 1L,
        rep_lon = zctas$center_lon[1],
        rep_lat = zctas$center_lat[1],
        rep_zip = as.character(zctas$zipcode[1]),
        stringsAsFactors = FALSE
      )
    ))
  }
  assignments <- as.integer(km$cluster)
  rep_rows <- lapply(seq_len(centers), function(i) {
    idx <- which(assignments == i)
    if (length(idx) == 0) return(NULL)
    ctr <- km$centers[i, ]
    d2 <- (coords[idx, "X"] - ctr[1])^2 + (coords[idx, "Y"] - ctr[2])^2
    best <- idx[which.min(d2)][1]
    data.frame(
      forecast_region = i,
      rep_lon = zctas$center_lon[best],
      rep_lat = zctas$center_lat[best],
      rep_zip = as.character(zctas$zipcode[best]),
      stringsAsFactors = FALSE
    )
  })
  rep_rows <- Filter(Negate(is.null), rep_rows)
  reps <- if (length(rep_rows) == 0) {
    data.frame(
      forecast_region = 1L,
      rep_lon = zctas$center_lon[1],
      rep_lat = zctas$center_lat[1],
      rep_zip = as.character(zctas$zipcode[1]),
      stringsAsFactors = FALSE
    )
  } else {
    dplyr::bind_rows(rep_rows)
  }
  list(assignments = assignments, reps = reps)
}

# Why: a side-effect transformation on the zips frame needs to happen at a
# known point in the pipeline; encapsulating it keeps order-of-application
# explicit.
# What: Joins zip -> place_name from the cached lookup, mutating
# zips$place_name in place.
# How: cache lookup + put.
# When: called at a fixed step in the build pipeline (see callers);
# ordering matters because later steps depend on the columns this writes.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
apply_cached_place_names <- function(zips) {
  lookup <- get_cached_zip_place_lookup()
  zips$place_name <- unname(lookup[zips$zipcode])
  zips
}

# Why: render the first frame quickly without waiting for all per-region
# forecasts; we use a single state-centroid forecast as the baseline.
# What: returns a list(temperature_f, wind_mph, wind_direction,
# wind_direction_degrees, pop_pct, short_forecast) sourced from a single
# api.weather.gov points request.
# How: calls get_points_metadata at (state_fast_lat, state_fast_lon),
# fetches hourly periods (falling back to forecast), picks the now period,
# and parses fields into the canonical scalar shape.
# When: invoked at the very start of build_fast_live_baseline, before the
# per-region pipeline kicks in.
# Impact: a slow or failing call here blocks the live first paint;
# empty_forecast_result is the safe fallback.
get_quick_live_forecast <- function() {
  cached <- cache_get("derived", "quick-live-forecast")
  if (!is.null(cached)) return(cached)

  meta <- get_points_metadata(state_fast_lat, state_fast_lon)
  if (is.null(meta)) {
    out <- empty_forecast_result()
    cache_put("derived", "quick-live-forecast", out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }

  periods <- get_forecast_periods(meta$forecast_hourly_url)
  if (is.null(periods)) periods <- get_forecast_periods(meta$forecast_url)
  period <- pick_forecast_period(periods, 0)
  if (is.null(period)) {
    out <- empty_forecast_result()
    cache_put("derived", "quick-live-forecast", out, ttl_seconds = ALERT_TTL_SECONDS)
    return(out)
  }

  temp_f <- safe_numeric(period$temperature %||% NA_real_)
  wind_mph <- parse_wind_mph(period$windSpeed %||% NA_character_)
  wind_dir <- normalize_wind_direction(period$windDirection %||% NA_character_)
  pop_pct <- safe_numeric((period$probabilityOfPrecipitation %||% list())$value %||% NA_real_)
  short_forecast <- as.character(period$shortForecast %||% period$detailedForecast %||% NA_character_)

  out <- list(
    temperature_f = temp_f,
    wind_mph = wind_mph,
    wind_direction = wind_dir,
    wind_direction_degrees = wind_direction_degrees(wind_dir),
    pop_pct = pop_pct,
    short_forecast = short_forecast
  )
  cache_put("derived", "quick-live-forecast", out, ttl_seconds = ALERT_TTL_SECONDS)
  out
}

# Why: produce a per-ZIP frame with sane forecast columns before any region
# refinements arrive, so the map can paint immediately on session start.
# What: returns a zip-shaped data.frame (or sf) with forecast_temperature_f,
# forecast_wind_mph, etc., temp/wind/pop risk scores, and the temperature
# pressure derived columns.
# How: starts from zip_static, applies cached place names, broadcasts the
# get_quick_live_forecast scalars to every row, scores per lat band, and
# appends the temperature_pressure columns.
# When: called at startup and whenever the live baseline cache expires.
# Impact: this is the "first paint" data - errors here mean the map shows
# blank or misleading defaults until the real region pipeline overrides.
build_fast_live_baseline <- function() {
  cached <- cache_get("derived", "fast-live-baseline")
  if (!is.null(cached)) {
    if (!"temperature_pressure_text" %in% names(cached)) {
      cached <- append_temperature_pressure_fields(cached)
      cache_put("derived", "fast-live-baseline", cached, ttl_seconds = ALERT_TTL_SECONDS)
    }
    return(cached)
  }
  zips <- zip_static
  zips <- apply_cached_place_names(zips)
  zips$horizon_label <- "Live"
  quick <- get_quick_live_forecast()

  zips$forecast_temperature_f <- quick$temperature_f %||% NA_real_
  zips$forecast_wind_mph <- quick$wind_mph %||% NA_real_
  zips$forecast_wind_dir <- quick$wind_direction %||% NA_character_
  zips$forecast_wind_dir_degrees <- quick$wind_direction_degrees %||% NA_real_
  zips$forecast_pop_pct <- quick$pop_pct %||% NA_real_
  zips$forecast_short <- quick$short_forecast %||% NA_character_

  zips$temp_risk_score <- vapply(
    zips$lat_band,
    function(lat_band) {
      profile <- lookup_band_profile(lat_band)
      temperature_risk(
        zips$forecast_temperature_f[1],
        profile$temp_comfort_low_f,
        profile$temp_comfort_high_f,
        profile$temp_record_low_f,
        profile$temp_record_high_f
      )
    },
    numeric(1)
  )
  zips$wind_risk_score <- rep(piecewise_score(zips$forecast_wind_mph[1], 15, 28, 45), nrow(zips))
  zips$pop_risk_score <- rep(piecewise_score(zips$forecast_pop_pct[1], 25, 50, 75), nrow(zips))
  zips$forecast_score <- pmin(1, 0.45 * zips$temp_risk_score + 0.30 * zips$wind_risk_score + 0.25 * zips$pop_risk_score)
  zips <- append_temperature_pressure_fields(zips)
  cache_put("derived", "fast-live-baseline", zips, ttl_seconds = ALERT_TTL_SECONDS)
  zips
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the matching row of risk_band_profiles for lat_band,
# falling back to row 1 if missing.
# How: row/element loop + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
lookup_band_profile <- function(lat_band) {
  idx <- match(lat_band, risk_band_profiles$lat_band)
  if (is.na(idx)) idx <- 1L
  risk_band_profiles[idx, , drop = FALSE]
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the band's annual-average temperature in F, falling back
# through profile -> DEFAULT_LAT_BAND_ANNUAL_AVG_TEMPS_F -> 44.
# How: row/element loop + guarded numeric coercion.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
lookup_band_annual_avg_temp <- function(lat_band) {
  profile <- lookup_band_profile(lat_band)
  annual <- safe_numeric(profile$temp_annual_avg_f %||% NA_real_)
  if (is.finite(annual)) return(annual)
  band_id <- suppressWarnings(as.integer(lat_band %||% NA_integer_))
  fallback <- safe_numeric(DEFAULT_LAT_BAND_ANNUAL_AVG_TEMPS_F[as.character(band_id)] %||% NA_real_)
  if (is.finite(fallback)) return(fallback)
  44
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Vectorised wrapper applying lookup_band_annual_avg_temp
# element-wise.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
vector_lookup_band_annual_avg_temp <- function(lat_band) {
  vapply(lat_band, lookup_band_annual_avg_temp, numeric(1))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Applies the standard NWS wind-chill formula for temp_f <= 50 and
# wind_mph >= 3, returning temp_f unchanged otherwise.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
wind_chill_temperature_f <- function(temp_f, wind_mph) {
  temp_f <- safe_numeric(temp_f)
  wind_mph <- safe_numeric(wind_mph)
  out <- temp_f
  valid <- is.finite(temp_f) & is.finite(wind_mph) & temp_f <= 50 & wind_mph >= 3
  if (any(valid)) {
    out[valid] <- 35.74 + 0.6215 * temp_f[valid] - 35.75 * (wind_mph[valid]^0.16) + 0.4275 * temp_f[valid] * (wind_mph[valid]^0.16)
  }
  out
}

# Why: the user-facing display needs a consistent rendering of this value
# across popups / summaries / legends.
# What: Formats the popup text describing whether apparent temp is
# above/at/below the local annual average, with a "wind chill adjusted"
# suffix when relevant.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: any change to the rendering shows up directly in popups / legends
# / summaries; keep callers' assumptions about output shape (e.g., "%s%%")
# stable.
format_temperature_pressure_text <- function(pressure_f = NA_real_, annual_avg_f = NA_real_, apparent_temp_f = NA_real_, actual_temp_f = NA_real_) {
  if (!is.finite(pressure_f) || !is.finite(annual_avg_f) || !is.finite(apparent_temp_f)) return("N/A")
  if (abs(pressure_f) < 0.5) {
    base <- sprintf("Near local average (%.0f°F vs %.0f°F avg)", apparent_temp_f, annual_avg_f)
  } else if (pressure_f > 0) {
    base <- sprintf("+%.0f°F above local avg (%.0f°F vs %.0f°F avg)", abs(pressure_f), apparent_temp_f, annual_avg_f)
  } else {
    base <- sprintf("-%.0f°F below local avg (%.0f°F vs %.0f°F avg)", abs(pressure_f), apparent_temp_f, annual_avg_f)
  }
  if (is.finite(actual_temp_f) && is.finite(apparent_temp_f) && apparent_temp_f <= actual_temp_f - 2) {
    sprintf("%s, wind chill adjusted", base)
  } else {
    base
  }
}

# Why: ZIP popups need the "feels-like vs annual avg" insight so users can
# understand how anomalous a given temperature is for that band.
# What: returns zips with annual_avg_temperature_f, apparent_temperature_f,
# temperature_pressure_f, and temperature_pressure_text columns appended.
# How: computes wind chill, takes pmin with actual temp as apparent temp,
# subtracts the per-band annual avg to get the "pressure", and renders text
# via format_temperature_pressure_text per row.
# When: called by build_fast_live_baseline and at the end of the forecast
# pipeline once forecast_temperature_f / forecast_wind_mph are populated.
# Impact: missing values cascade into "N/A" popup labels; the wind-chill
# threshold is a 2 F gap to avoid noise on calm days.
append_temperature_pressure_fields <- function(zips) {
  if (is.null(zips) || nrow(zips) == 0) return(zips)
  annual_avg <- vector_lookup_band_annual_avg_temp(zips$lat_band)
  actual_temp <- safe_numeric(zips$forecast_temperature_f)
  wind_mph <- safe_numeric(zips$forecast_wind_mph)
  apparent_temp <- actual_temp
  chill_temp <- wind_chill_temperature_f(actual_temp, wind_mph)
  chill_mask <- is.finite(chill_temp) & is.finite(actual_temp) & chill_temp < actual_temp
  apparent_temp[chill_mask] <- chill_temp[chill_mask]
  pressure <- apparent_temp - annual_avg
  pressure[!is.finite(apparent_temp) | !is.finite(annual_avg)] <- NA_real_
  zips$annual_avg_temperature_f <- annual_avg
  zips$apparent_temperature_f <- apparent_temp
  zips$temperature_pressure_f <- pressure
  zips$temperature_pressure_text <- vapply(
    seq_len(nrow(zips)),
    function(i) format_temperature_pressure_text(
      pressure_f = pressure[i],
      annual_avg_f = annual_avg[i],
      apparent_temp_f = apparent_temp[i],
      actual_temp_f = actual_temp[i]
    ),
    character(1)
  )
  zips
}

# Why: a downstream consumer needs the assembled output in a single call
# rather than calling the underlying primitives separately.
# What: Builds the api.weather.gov /points/{lat},{lon} URL with 4 decimal
# precision (the NWS rounds to grid anyway).
# How: see body — short helper.
# When: called by the layer's top-level builder when assembling the
# user-visible output.
# Impact: any new column or row source needs to be added here AND in the
# layer's standardise_* schema; mismatched schemas show up as silent column
# drops downstream.
build_points_url <- function(lat, lon) sprintf("https://api.weather.gov/points/%.4f,%.4f", lat, lon)

# Why: the upstream payload arrives in an unstructured shape that the rest
# of the pipeline can't consume directly.
# What: Extracts the maximum integer from an NWS wind-speed string like "10
# to 15 mph" and returns it as numeric mph (NA on no digits).
# How: see body — short helper.
# When: called immediately after the upstream HTTP fetch resolves, before
# the result is handed to the scorer or shape converter.
# Impact: upstream schema drift is the main failure mode; the function
# tries multiple field-name spellings to absorb minor changes.
parse_wind_mph <- function(wind_speed_text) {
  if (is.null(wind_speed_text) || is.na(wind_speed_text) || !nzchar(wind_speed_text)) return(NA_real_)
  nums <- safe_numeric(unlist(regmatches(wind_speed_text, gregexpr("[0-9]+", wind_speed_text))))
  nums <- nums[is.finite(nums)]
  if (length(nums) == 0) return(NA_real_)
  max(nums)
}

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Canonicalises a wind direction string to an 8/16-point compass code
# (e.g. "Northeast" -> "NE"), returning NA when unrecognised.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_wind_direction <- function(direction_text = NA_character_) {
  txt <- toupper(trimws(safe_string(direction_text)))
  if (!nzchar(txt)) return(NA_character_)
  txt <- gsub("[^A-Z]", "", txt)
  alias_map <- c(
    NORTH = "N", SOUTH = "S", EAST = "E", WEST = "W",
    NORTHEAST = "NE", NORTHWEST = "NW", SOUTHEAST = "SE", SOUTHWEST = "SW",
    NNE = "NNE", ENE = "ENE", ESE = "ESE", SSE = "SSE",
    SSW = "SSW", WSW = "WSW", WNW = "WNW", NNW = "NNW"
  )
  if (txt %in% names(alias_map)) return(alias_map[[txt]])
  if (txt %in% unname(alias_map)) return(txt)
  NA_character_
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Converts a 16-point compass label ("N", "NNE", ...) into a bearing
# in degrees, returning NA_real_ if not recognised.
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
wind_direction_degrees <- function(direction_text = NA_character_) {
  dir <- normalize_wind_direction(direction_text)
  if (!nzchar(dir %||% "")) return(NA_real_)
  bearing_map <- c(
    N = 0, NNE = 22.5, NE = 45, ENE = 67.5,
    E = 90, ESE = 112.5, SE = 135, SSE = 157.5,
    S = 180, SSW = 202.5, SW = 225, WSW = 247.5,
    W = 270, WNW = 292.5, NW = 315, NNW = 337.5
  )
  if (!dir %in% names(bearing_map)) return(NA_real_)
  safe_numeric(bearing_map[[dir]])
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Maps a horizon key string to its hour offset (0/24/48/72) for
# forecast period selection.
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
horizon_hours_from_key <- function(horizon_key) {
  switch(horizon_key %||% "live", live = 0, `24h` = 24, `48h` = 48, `72h` = 72, 0)
}

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: De-duplicates and coerces selected_features to a unique character
# vector (NULL -> empty character).
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_feature_selection <- function(selected_features = character(0)) {
  unique(as.character(selected_features %||% character(0)))
}

# Why: downstream lookups and grepl calls need a canonical text form so
# casing / punctuation drift can't cause false misses.
# What: Coerces a primary_map id to a known PRIMARY_MAP_CHOICES value,
# falling back to DEFAULT_PRIMARY_MAP for unknown inputs.
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
normalize_primary_map <- function(primary_map = DEFAULT_PRIMARY_MAP) {
  primary_map <- as.character(primary_map %||% DEFAULT_PRIMARY_MAP)[1]
  if (!nzchar(primary_map) || !primary_map %in% unname(PRIMARY_MAP_CHOICES)) DEFAULT_PRIMARY_MAP else primary_map
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the human-readable name (PRIMARY_MAP_CHOICES key) for a
# primary_map id, defaulting to "Normalized environmental risk".
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
primary_map_display_name <- function(primary_map = DEFAULT_PRIMARY_MAP) {
  primary_map <- normalize_primary_map(primary_map)
  out <- names(PRIMARY_MAP_CHOICES)[match(primary_map, unname(PRIMARY_MAP_CHOICES))]
  if (!nzchar(out %||% "")) "Normalized environmental risk" else out
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Maps a primary_map selection to the implicit hazard features it
# depends on (e.g., "wind" -> c("wind","convective")).
# How: branch dispatch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
primary_map_features <- function(primary_map = DEFAULT_PRIMARY_MAP) {
  primary_map <- normalize_primary_map(primary_map)
  normalize_feature_selection(switch(
    primary_map,
    environmental = ENVIRONMENTAL_MAP_FEATURES,
    temperature = "temperature",
    wind = c("wind", "convective"),
    precipitation = "precipitation",
    qpf_flood = c("qpf_flood", "convective"),
    winter = "winter",
    fire = c("fire", "air"),
    convective = "convective",
    heat = "heat",
    cold = "cold",
    air = c("air", "fire"),
    radiation = "radiation",
    seismic = "seismic",
    character(0)
  ))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE when the chosen primary map renders ZIP polygons
# (currently always TRUE - reserved for future raster maps).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
primary_map_shows_polygons <- function(primary_map = DEFAULT_PRIMARY_MAP) {
  TRUE
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Adds TRANSPORT_SUPPORT_FEATURES to selected_features when
# include_transport is TRUE, otherwise returns features unchanged.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
expand_transport_features <- function(selected_features = character(0), include_transport = FALSE) {
  features <- normalize_feature_selection(selected_features)
  if (isTRUE(include_transport)) {
    features <- unique(c(features, TRANSPORT_SUPPORT_FEATURES))
  }
  features
}

# Why: many parts of the build pipeline need a uniform "do we need X?" view
# of the active feature set so they can skip unused fetches.
# What: returns a list with display_features, effective_features, and a
# series of needs_* booleans (flood/winter/fire/etc.).
# How: expand_transport_features for the effective set, then test set
# membership against display vs effective for fine-grained gating.
# When: called once per build cycle by external_module_plan and the master
# zip pipeline.
# Impact: a missing feature flag here causes silent under-fetching of the
# corresponding hazard layer for the rest of the cycle.
compute_feature_requirements <- function(selected_features = character(0), include_transport = FALSE) {
  effective_features <- expand_transport_features(selected_features, include_transport = include_transport)
  display_features <- normalize_feature_selection(selected_features)
  list(
    display_features = display_features,
    effective_features = effective_features,
    needs_flood = "qpf_flood" %in% effective_features,
    needs_full_flood_detail = "qpf_flood" %in% display_features,
    needs_winter = any(c("winter", "cold") %in% effective_features),
    needs_fire = "fire" %in% effective_features,
    needs_convective = "convective" %in% effective_features,
    needs_heat = "heat" %in% effective_features,
    needs_air = "air" %in% effective_features,
    needs_radiation = "radiation" %in% effective_features,
    needs_seismic = "seismic" %in% effective_features,
    needs_uv = any(c("heat", "radiation") %in% effective_features),
    needs_transport = isTRUE(include_transport)
  )
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the static list describing each external data module (id,
# label, requirement key, live/future modes, optional half_life_hours).
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_module_registry <- function() {
  list(
    list(id = "flood_guidance", label = "Flood guidance", requirement = "needs_flood", live_mode = "native", future_mode = "native"),
    list(id = "winter_guidance", label = "Winter guidance", requirement = "needs_winter", live_mode = "native", future_mode = "native"),
    list(id = "fire_guidance", label = "Fire guidance", requirement = "needs_fire", live_mode = "native", future_mode = "native"),
    list(id = "convective_guidance", label = "Convective guidance", requirement = "needs_convective", live_mode = "native", future_mode = "native"),
    list(id = "convective_lightning", label = "Lightning carry-forward", requirement = "needs_convective", live_mode = "native", future_mode = "carry_forward", half_life_hours = 3),
    list(id = "heat_guidance", label = "Heat guidance", requirement = "needs_heat", live_mode = "native", future_mode = "native"),
    list(id = "uv_guidance", label = "UV guidance", requirement = "needs_uv", live_mode = "native", future_mode = "native"),
    list(id = "radiation_monitor", label = "Radiation monitoring", requirement = "needs_radiation", live_mode = "native", future_mode = "carry_forward", half_life_hours = 36),
    list(id = "radiation_incident", label = "Radiation incidents", requirement = "needs_radiation", live_mode = "native", future_mode = "carry_forward", half_life_hours = 72),
    list(id = "seismic_guidance", label = "Seismic guidance", requirement = "needs_seismic", live_mode = "native", future_mode = "carry_forward", half_life_hours = 48),
    list(id = "air_guidance", label = "Air-quality guidance", requirement = "needs_air", live_mode = "native", future_mode = "native"),
    list(id = "transport_guidance", label = "Transportation guidance", requirement = "needs_transport", live_mode = "native", future_mode = "carry_forward", half_life_hours = 12)
  )
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Predicate: TRUE if the requirement flag named by meta$requirement
# is set in the requirements list.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_module_requirement_active <- function(meta, requirements) {
  req_name <- safe_string(meta$requirement)
  isTRUE(requirements[[req_name]])
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the run mode for a module ("native"/"carry_forward"/"skip")
# given the horizon - live always uses live_mode.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
external_module_run_mode <- function(meta, horizon_key = "live") {
  if (identical(horizon_key %||% "live", "live")) return(as.character(meta$live_mode %||% "native"))
  as.character(meta$future_mode %||% meta$live_mode %||% "skip")
}

# Why: build the per-tick to-do list of which external modules to run and
# how, given the user's feature selection and chosen horizon.
# What: returns a list of module entries (the registry meta plus active,
# mode, half_life_hours), filtered to only the active ones.
# How: computes feature_requirements, walks external_module_registry, and
# enriches each meta with its run mode and active flag.
# When: called from load_external_risk_bundle at the start of each build pass
# to decide which external modules to fetch this tick.
# Impact: a wrong active flag here either fires unneeded network calls or
# leaves a hazard score at zero.
build_external_module_plan <- function(horizon_key = "live", selected_features = character(0), include_transport = FALSE) {
  requirements <- compute_feature_requirements(selected_features, include_transport = include_transport)
  plan <- lapply(external_module_registry(), function(meta) {
    mode <- external_module_run_mode(meta, horizon_key = horizon_key)
    active <- external_module_requirement_active(meta, requirements) && !identical(mode, "skip")
    c(
      meta,
      list(
        active = isTRUE(active),
        mode = mode,
        half_life_hours = safe_numeric(meta$half_life_hours %||% NA_real_)
      )
    )
  })
  Filter(function(entry) isTRUE(entry$active), plan)
}

# Why: a downstream consumer needs the assembled output in a single call
# rather than calling the underlying primitives separately.
# What: Indexes a module_plan list by id so callers can look up a module's
# metadata in O(1).
# How: row/element loop + named vector build.
# When: called by the layer's top-level builder when assembling the
# user-visible output.
# Impact: any new column or row source needs to be added here AND in the
# layer's standardise_* schema; mismatched schemas show up as silent column
# drops downstream.
build_external_module_plan_map <- function(module_plan = list()) {
  if (!length(module_plan)) return(list())
  stats::setNames(module_plan, vapply(module_plan, function(entry) as.character(entry$id %||% ""), character(1)))
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Calls progress(value, detail) when progress is a function,
# otherwise no-ops - used for optional Shiny Progress objects.
# How: HTTP JSON fetch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
notify_progress <- function(progress, value = NULL, detail = NULL) {
  if (!is.function(progress)) return(invisible(NULL))
  progress(value = value, detail = detail)
  invisible(NULL)
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns the exponential decay factor exp(-ln2 * h / half_life) for
# the horizon's hour offset, or 1 for "live"/0.
# How: cache lookup + put + HTTP JSON fetch.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
horizon_live_decay <- function(horizon_key, half_life_hours = 24) {
  hrs <- horizon_hours_from_key(horizon_key)
  if (!is.finite(hrs) || hrs <= 0) return(1)
  exp(-log(2) * hrs / max(half_life_hours, 1e-9))
}

# Why: a side-effect transformation on the zips frame needs to happen at a
# known point in the pipeline; encapsulating it keeps order-of-application
# explicit.
# What: Vectorised carry-forward: scales live_score by horizon_live_decay
# and clamps to [0,1] so future horizons fade rather than vanish.
# How: cache lookup + put + HTTP JSON fetch.
# When: called at a fixed step in the build pipeline (see callers);
# ordering matters because later steps depend on the columns this writes.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
apply_live_decay <- function(live_score, horizon_key, half_life_hours = 24) {
  score <- safe_numeric(live_score)
  score[!is.finite(score)] <- 0
  pmin(1, pmax(0, score * horizon_live_decay(horizon_key, half_life_hours = half_life_hours)))
}

# Why: api.weather.gov requires two requests (points -> forecast); we cache
# the points response per coordinate to amortise across all horizons.
# What: returns list(forecast_hourly_url, forecast_url) for the lat/lon, or
# NULL if the API call fails.
# How: caches under "points::lat,lon" with 24h TTL; on miss, calls
# build_points_url + http_json and pulls properties$forecast(Hourly).
# When: invoked by every band/region forecast scorer before fetching
# periods.
# Impact: a stale cached entry can pin a region to a defunct grid URL until
# the 24h TTL expires; the cache key is rounded to 3 decimals to coalesce
# nearby points.
get_points_metadata <- function(lat, lon) {
  key <- sprintf("%.3f,%.3f", lat, lon)
  cached <- cache_get("points", key)
  if (!is.null(cached)) return(cached)
  payload <- safely(http_json(build_points_url(lat, lon)))
  if (is.null(payload)) return(NULL)
  props <- payload$properties %||% list()
  meta <- list(
    forecast_hourly_url = props$forecastHourly %||% NA_character_,
    forecast_url = props$forecast %||% NA_character_
  )
  cache_put("points", key, meta, ttl_seconds = 24 * 3600)
  meta
}

# Why: downstream callers need this lookup encapsulated so cache + fallback
# handling lives in one place.
# What: Fetches the periods list from a forecast URL, caching under
# "forecast::url" with FORECAST_TTL_SECONDS, returning NULL on failure.
# How: cache lookup + put + HTTP JSON fetch + row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
get_forecast_periods <- function(url) {
  if (is.null(url) || is.na(url) || !nzchar(url)) return(NULL)
  cached <- cache_get("forecast", url)
  if (!is.null(cached)) return(cached)
  payload <- safely(http_json(url))
  if (is.null(payload)) return(NULL)
  periods <- payload$properties$periods %||% list()
  cache_put("forecast", url, periods, ttl_seconds = FORECAST_TTL_SECONDS)
  periods
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Selects the forecast period whose [startTime, endTime] window
# contains now+horizon_hours, or the period closest in time if none match.
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
pick_forecast_period <- function(periods, horizon_hours) {
  if (is.null(periods) || length(periods) == 0) return(NULL)
  starts <- vapply(periods, function(p) as.numeric(parse_iso_time(p$startTime %||% NA_character_)), numeric(1))
  ends <- vapply(periods, function(p) as.numeric(parse_iso_time(p$endTime %||% NA_character_)), numeric(1))
  target <- as.numeric(Sys.time() + horizon_hours * 3600)
  within <- which(starts <= target & ends >= target)
  if (length(within) > 0) return(periods[[within[1]]])
  periods[[which.min(abs(starts - target))]]
}

# Why: the canonical empty shape is needed wherever the upstream feed is
# missing or fails so downstream rbind / merge calls don't break the
# schema.
# What: Returns a sentinel forecast result list (zero scores, NA fields)
# used as a safe fallback when the upstream call fails.
# How: cache lookup + put.
# When: called as the fallback in every fetcher / compute step when the
# upstream feed is missing or returns no rows.
# Impact: changing the column set requires a matching update in every
# fetcher / compute step that returns this empty shape on failure.
empty_forecast_result <- function() {
  list(
    score = 0,
    temp_score = 0,
    wind_score = 0,
    pop_score = 0,
    temperature_f = NA_real_,
    wind_mph = NA_real_,
    wind_direction = NA_character_,
    wind_direction_degrees = NA_real_,
    pop_pct = NA_real_,
    short_forecast = NA_character_
  )
}

# Why: produce one forecast result (and its temp/wind/pop scores) per
# latitude band per horizon, cached so each band is fetched at most once.
# What: returns a list (score, temp_score, wind_score, pop_score,
# temperature_f, wind_mph, wind_direction*, pop_pct, short_forecast).
# How: looks up the band's representative point, fetches periods through
# get_points_metadata + get_forecast_periods, picks the right period,
# scores via temperature_risk + piecewise_score with the band's profile.
# When: called by the band-aware forecast pipeline for live and future
# horizons.
# Impact: errors fall through to empty_forecast_result so the band shows
# no risk; profile thresholds set the band's sensitivity vs others.
score_forecast_for_band <- function(lat_band, horizon_key) {
  cache_name <- paste0("band-", lat_band, "-", horizon_key)
  cached <- cache_get("horizon", cache_name)
  if (!is.null(cached)) return(cached)
  rep_row <- band_reps[band_reps$lat_band == lat_band, , drop = FALSE]
  if (nrow(rep_row) == 0) {
    out <- empty_forecast_result()
    cache_put("horizon", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
    return(out)
  }
  meta <- get_points_metadata(rep_row$rep_lat[1], rep_row$rep_lon[1])
  if (is.null(meta)) {
    out <- empty_forecast_result()
    cache_put("horizon", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
    return(out)
  }
  periods <- get_forecast_periods(meta$forecast_hourly_url)
  if (is.null(periods)) periods <- get_forecast_periods(meta$forecast_url)
  period <- pick_forecast_period(periods, horizon_hours_from_key(horizon_key))
  if (is.null(period)) {
    out <- empty_forecast_result()
    cache_put("horizon", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
    return(out)
  }
  profile <- lookup_band_profile(lat_band)
  temp_f <- safe_numeric(period$temperature %||% NA_real_)
  wind_mph <- parse_wind_mph(period$windSpeed %||% NA_character_)
  wind_dir <- normalize_wind_direction(period$windDirection %||% NA_character_)
  pop_pct <- safe_numeric((period$probabilityOfPrecipitation %||% list())$value %||% NA_real_)
  short_forecast <- as.character(period$shortForecast %||% period$detailedForecast %||% NA_character_)
  temp_score <- temperature_risk(temp_f, profile$temp_comfort_low_f, profile$temp_comfort_high_f, profile$temp_record_low_f, profile$temp_record_high_f)
  wind_score <- piecewise_score(wind_mph, profile$low_wind_mph, profile$medium_wind_mph, profile$high_wind_mph)
  pop_score <- piecewise_score(pop_pct, profile$low_pop_pct, profile$medium_pop_pct, profile$high_pop_pct)
  combined <- pmin(1, 0.45 * temp_score + 0.30 * wind_score + 0.25 * pop_score)
  out <- list(
    score = as.numeric(combined),
    temp_score = as.numeric(temp_score),
    wind_score = as.numeric(wind_score),
    pop_score = as.numeric(pop_score),
    temperature_f = temp_f,
    wind_mph = wind_mph,
    wind_direction = wind_dir,
    wind_direction_degrees = wind_direction_degrees(wind_dir),
    pop_pct = pop_pct,
    short_forecast = short_forecast
  )
  cache_put("horizon", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
  out
}

# Why: per-region (k-means cluster) forecast lookup that captures the actual
# weather scalars but skips band-specific scoring (those happen later).
# What: returns the same shape as score_forecast_for_band but always with
# zero scores - only the raw temp/wind/pop fields are filled.
# How: same flow (rep point -> points -> periods -> pick) but does not
# call temperature_risk / piecewise_score because per-zip scoring is done
# downstream against per-zip profiles.
# When: invoked for each forecast_region during the pipeline assembly.
# Impact: changing what's pulled here re-shapes which scalar fields zips
# can see in popups; scoring is deliberately deferred to keep cache hits.
fetch_forecast_for_region <- function(region_id, horizon_key) {
  region_id <- suppressWarnings(as.integer(region_id %||% NA_integer_))
  cache_name <- paste0("forecast-region-", region_id, "-", horizon_key)
  cached <- cache_get("horizon", cache_name)
  if (!is.null(cached)) return(cached)
  # Failure-mode TTL: a transient NWS outage shouldn't pin every ZIP in
  # this region to "N/A" for the next half hour. Cache empty results for
  # ~60 s so the next refresh retries the upstream call. Successful
  # results still get the full FORECAST_TTL_SECONDS below.
  failure_ttl <- min(60L, FORECAST_TTL_SECONDS)
  rep_row <- forecast_region_reps[forecast_region_reps$forecast_region == region_id, , drop = FALSE]
  if (nrow(rep_row) == 0) {
    out <- empty_forecast_result()
    cache_put("horizon", cache_name, out, ttl_seconds = failure_ttl)
    return(out)
  }
  meta <- get_points_metadata(rep_row$rep_lat[1], rep_row$rep_lon[1])
  if (is.null(meta)) {
    out <- empty_forecast_result()
    cache_put("horizon", cache_name, out, ttl_seconds = failure_ttl)
    return(out)
  }
  periods <- get_forecast_periods(meta$forecast_hourly_url)
  if (is.null(periods)) periods <- get_forecast_periods(meta$forecast_url)
  period <- pick_forecast_period(periods, horizon_hours_from_key(horizon_key))
  if (is.null(period)) {
    out <- empty_forecast_result()
    cache_put("horizon", cache_name, out, ttl_seconds = failure_ttl)
    return(out)
  }
  temp_f <- safe_numeric(period$temperature %||% NA_real_)
  wind_mph <- parse_wind_mph(period$windSpeed %||% NA_character_)
  wind_dir <- normalize_wind_direction(period$windDirection %||% NA_character_)
  pop_pct <- safe_numeric((period$probabilityOfPrecipitation %||% list())$value %||% NA_real_)
  short_forecast <- as.character(period$shortForecast %||% period$detailedForecast %||% NA_character_)
  out <- list(
    score = 0,
    temp_score = 0,
    wind_score = 0,
    pop_score = 0,
    temperature_f = temp_f,
    wind_mph = wind_mph,
    wind_direction = wind_dir,
    wind_direction_degrees = wind_direction_degrees(wind_dir),
    pop_pct = pop_pct,
    short_forecast = short_forecast
  )
  cache_put("horizon", cache_name, out, ttl_seconds = FORECAST_TTL_SECONDS)
  out
}

# Why: downstream consumers need a 0..1 numeric risk for this signal so it
# can fuse with other family scores via noisy-OR.
# What: Maps a UV index value to a 0..1 score using piecewise_score(3, 6,
# 9) - aligned to the EPA UV exposure bands.
# How: guarded numeric coercion.
# When: called per row inside the matching fetcher / compute step; results
# land in the per-zip or per-road score column the rest of the layer reads.
# Impact: the keyword / threshold table here is the lever for how
# aggressively this signal lights up; broadening keywords surfaces more
# rows at lower bands.
score_uv_value <- function(uv_value) {
  if (!is.finite(uv_value)) return(0)
  piecewise_score(uv_value, 3, 6, 9)
}

# Why: the upstream payload arrives in an unstructured shape that the rest
# of the pipeline can't consume directly.
# What: Pulls UV_INDEX (with UV_VALUE as legacy fallback) and UV_ALERT
# (case-insensitive) from a heterogeneous EPA UV daily JSON payload,
# returning list(uv_value, uv_alert).
# How: guarded numeric coercion.
# When: called immediately after the upstream HTTP fetch resolves, before
# the result is handed to the scorer or shape converter.
# Impact: upstream schema drift is the main failure mode; the function
# tries multiple field-name spellings to absorb minor changes.
parse_uv_daily_payload <- function(payload) {
  if (is.null(payload)) return(list(uv_value = NA_real_, uv_alert = FALSE))
  row <- NULL
  if (is.data.frame(payload) && nrow(payload) > 0) {
    row <- payload[1, , drop = FALSE]
  } else if (is.list(payload) && length(payload) > 0) {
    if (is.data.frame(payload[[1]]) && nrow(payload[[1]]) > 0) {
      row <- payload[[1]][1, , drop = FALSE]
    } else {
      row <- payload
    }
  }
  # EPA UV API returns the headline value in UV_INDEX (the legacy UV_VALUE
  # name is kept as a fallback in case the schema regresses). The alert flag
  # is sometimes a numeric 0/1 string and sometimes "Y"/"N", so we accept
  # either.
  uv_value <- suppressWarnings(as.numeric(
    (row[["UV_INDEX"]] %||% row[["uv_index"]] %||%
     row[["UV_VALUE"]] %||% row[["uv_value"]] %||% NA_real_)[1]
  ))
  uv_alert_raw <- tolower(as.character((row[["UV_ALERT"]] %||% row[["uv_alert"]] %||% "")[1]))
  uv_alert <- nzchar(uv_alert_raw) && uv_alert_raw %in% c("y", "yes", "1", "true")
  list(uv_value = uv_value, uv_alert = uv_alert)
}
