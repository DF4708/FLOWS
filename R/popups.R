# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

# R/popups.R — auto-extracted from global.R during the modular split.
# Edit functions here; do not move them back into global.R unless you also update the loader.

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Escapes &, <, >, and quotes in x for safe interpolation into HTML
# strings; coerces NULL to "".
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
escape_html <- function(x) {
  htmltools::htmlEscape(safe_string(x))
}

# Why: render the alert row in a popup with the right colour, link styling,
# and "all clear / forecast / no alert" fallbacks.
# What: returns an HTML fragment (a <span>/<strong>/<a>) styled with the
# alert tier's colour and optional proximity note suffix.
# How: branches on whether event/url/score/forecast text are present and
# composes the right combination; uses alert_notification_color for tier-
# coloured output.
# When: invoked per ZIP (or per alert in a multi-alert popup) by
# build_popup_html_fields.
# Impact: this is the public-facing summary of an alert per ZIP - HTML
# escape bugs here would expose XSS via NWS event text.
alert_field_html <- function(event, score, url, forecast_short, risk_label, proximity_note = FALSE) {
  event_text <- trimws(safe_string(event))
  url_text <- trimws(ifelse(is.na(url %||% NA_character_), "", safe_string(url)))
  forecast_text <- trimws(safe_string(forecast_short))
  proximity_suffix <- if (isTRUE(proximity_note)) " Risk increased due to proximity with a red alert." else ""

  if (nzchar(event_text)) {
    color <- alert_notification_color(event_text, default = "#2b7a0b")[1]
    if (nzchar(url_text)) {
      return(sprintf(
        '<strong><a href="%s" target="_blank" style="color:%s; text-decoration:underline;">%s</a></strong><span style="color:%s;">%s</span>',
        escape_html(url_text), color, escape_html(event_text), color, escape_html(proximity_suffix)
      ))
    }
    if (is.finite(score) && score >= RISK_YELLOW_MIN) {
      return(sprintf(
        '<strong style="color:%s;">%s</strong><span style="color:%s;">%s</span>',
        color, escape_html(event_text), color, escape_html(proximity_suffix)
      ))
    }
    return(sprintf(
      '<span style="color:%s;">%s%s</span>',
      color, escape_html(event_text), escape_html(proximity_suffix)
    ))
  }

  if (is.finite(score) && score < RISK_YELLOW_MIN) {
    return(sprintf(
      '<span style="color:#2b7a0b;">All clear.%s</span>',
      escape_html(proximity_suffix)
    ))
  }

  if (nzchar(forecast_text)) {
    return(sprintf(
      '<span style="color:#2b7a0b;">Forecast conditions: %s%s</span>',
      escape_html(forecast_text), escape_html(proximity_suffix)
    ))
  }

  sprintf(
    '<span style="color:#666;">No active government alert. Risk level: %s.%s</span>',
    escape_html(risk_label), escape_html(proximity_suffix)
  )
}

# Why: the data shape needs to change between two pipeline stages and
# centralising the split/join keeps schema invariants in one place.
# What: Splits a multi-alert string on the ALERT_LINK_SEP delimiter into a
# unique trimmed character vector (drops blanks and NAs).
# How: row/element loop.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
split_alert_field_values <- function(x) {
  txt <- safe_string(x)
  if (length(txt) == 0) return(character(0))
  txt <- txt[!is.na(txt) & nzchar(trimws(txt))]
  if (length(txt) == 0) return(character(0))
  pieces <- unlist(strsplit(txt, ALERT_LINK_SEP, fixed = TRUE), use.names = FALSE)
  pieces <- trimws(as.character(pieces %||% character(0)))
  unique(pieces[nzchar(pieces)])
}

# Why: a single ZIP can have multiple concurrent alerts; we need a stacked
# render rather than collapsing to one row.
# What: returns a single HTML string containing one styled <div> per alert,
# with optional proximity-note line at the end.
# How: split_alert_field_values on events/urls, pads url_vec to events
# length, calls alert_field_html per index and concatenates.
# When: called by build_popup_html_fields when alert_event_list contains
# more than one alert.
# Impact: ordering and pairing of events to urls happens here - mismatch
# silently links the wrong URL to the wrong alert.
alert_field_multi_html <- function(events, score, urls, forecast_short, risk_label, proximity_note = FALSE) {
  event_vec <- split_alert_field_values(events)
  url_vec <- split_alert_field_values(urls)
  if (length(event_vec) == 0) {
    return(alert_field_html(NA_character_, score, NA_character_, forecast_short, risk_label, proximity_note))
  }
  if (length(url_vec) < length(event_vec)) {
    url_vec <- c(url_vec, rep("", length(event_vec) - length(url_vec)))
  }
  item_html <- vapply(
    seq_along(event_vec),
    function(i) {
      sprintf('<div style="margin-bottom:0.12rem;">%s</div>', alert_field_html(event_vec[i], score, url_vec[i], forecast_short, risk_label, proximity_note = FALSE))
    },
    character(1)
  )
  if (isTRUE(proximity_note)) {
    item_html <- c(item_html, '<div style="color:#8a6d00;">Risk increased due to proximity with a red alert.</div>')
  }
  paste(item_html, collapse = "")
}

# Why: the user-facing display needs a consistent rendering of this value
# across popups / summaries / legends.
# What: Formats a numeric score 0..1 as a "NN%" string clamped to [0,100],
# using na_label for non-finite values.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: any change to the rendering shows up directly in popups / legends
# / summaries; keep callers' assumptions about output shape (e.g., "%s%%")
# stable.
format_score_pct <- function(score, digits = 0, na_label = "0%") {
  val <- safe_numeric(score)
  if (length(val) == 0) return(na_label)
  out <- rep(na_label, length(val))
  ok <- is.finite(val)
  if (any(ok)) {
    out[ok] <- sprintf(paste0("%.", digits, "f%%"), 100 * pmin(1, pmax(0, val[ok])))
  }
  out
}

# Why: ZIP popups want a small visual compass showing N/MN and the current
# wind vector to make wind direction obvious at a glance.
# What: returns an HTML fragment containing an inline <svg> with a circle,
# an N arrow, an MN (magnetic north) arrow, and a wind arrow with mph label.
# How: closure helpers (arrow_tip, arrow_wing, build_arrow) compute SVG line
# and polygon coordinates from a bearing in degrees; the magnetic-north
# offset is WI_MAGNETIC_DECLINATION_DEG.
# When: called by build_popup_html_fields once per popup.
# Impact: the visual identity of the popup; bearing math errors here rotate
# the wind arrow incorrectly without throwing.
popup_compass_svg_html <- function(wind_direction = NA_character_, wind_direction_bearing = NA_real_, wind_speed_mph = NA_real_) {
  center_x <- 80
  center_y <- 80
  direction_deg <- safe_numeric(wind_direction_bearing)
  if (!is.finite(direction_deg)) direction_deg <- wind_direction_degrees(normalize_wind_direction(wind_direction))
  arrow_tip <- function(angle_deg, radius = 52) {
    rad <- angle_deg * pi / 180
    c(x = center_x + radius * sin(rad), y = center_y - radius * cos(rad))
  }
  arrow_wing <- function(angle_deg, length = 10, spread_deg = 150) {
    left_rad <- (angle_deg + spread_deg) * pi / 180
    right_rad <- (angle_deg - spread_deg) * pi / 180
    c(
      center_x + length * sin(left_rad), center_y - length * cos(left_rad),
      center_x + length * sin(right_rad), center_y - length * cos(right_rad)
    )
  }
  build_arrow <- function(angle_deg, color, label, line_width = 3.2, radius = 52, label_radius = 67) {
    tip <- arrow_tip(angle_deg, radius = radius)
    wings <- arrow_wing(angle_deg, length = 11)
    label_xy <- arrow_tip(angle_deg, radius = label_radius)
    sprintf(
      paste0(
        '<line x1="%0.1f" y1="%0.1f" x2="%0.1f" y2="%0.1f" stroke="%s" stroke-width="%0.1f" stroke-linecap="round"/>',
        '<polygon points="%0.1f,%0.1f %0.1f,%0.1f %0.1f,%0.1f" fill="%s"/>',
        '<text x="%0.1f" y="%0.1f" fill="%s" font-size="11" font-weight="700" text-anchor="middle" dominant-baseline="middle">%s</text>'
      ),
      center_x, center_y, tip[["x"]], tip[["y"]], color, line_width,
      tip[["x"]], tip[["y"]], wings[[1]], wings[[2]], wings[[3]], wings[[4]], color,
      label_xy[["x"]], label_xy[["y"]], color, escape_html(label)
    )
  }
  wind_label <- if (is.finite(wind_speed_mph)) sprintf("%.0f mph", wind_speed_mph) else "Wind"
  wind_arrow <- if (is.finite(direction_deg)) build_arrow(direction_deg, "#1d5fd3", wind_label, line_width = 3.4, radius = 49, label_radius = 70) else ""
  sprintf(
    paste0(
      '<div style="display:flex; justify-content:center; margin:0 auto 0.45rem auto;">',
      '<svg viewBox="0 0 160 160" width="118" height="118" role="img" aria-label="Compass">',
      '<circle cx="80" cy="80" r="58" fill="#ffffff" fill-opacity="0.96" stroke="#444444" stroke-width="1.4"/>',
      '<circle cx="80" cy="80" r="4.5" fill="#202020"/>',
      '%s',
      '%s',
      '%s',
      '</svg>',
      '</div>'
    ),
    build_arrow(0, "#111111", "N"),
    build_arrow(WI_MAGNETIC_DECLINATION_DEG, "#c92a2a", "MN", line_width = 2.8, radius = 44, label_radius = 58),
    wind_arrow
  )
}

# Why: internal helper used by callers in the same module; isolating it
# keeps the call sites free of repeated boilerplate.
# What: Returns "<div><strong>label:</strong> value</div>" used to render a
# single popup field row.
# How: see body — short helper.
# When: called from a small set of internal call sites within this module.
# Impact: consult call sites before changing the signature; a regression
# here propagates through every caller.
popup_value_row_html <- function(label, value_html) {
  sprintf('<div style="margin-bottom:0.18rem;"><strong>%s:</strong> %s</div>', escape_html(label), value_html)
}

# Why: assemble the full ZIP popup HTML from a long list of pre-computed
# fields, in one pass per ZIP.
# What: returns a string with the popup compass SVG, ZIP heading, and a
# stack of label/value rows (county, city, view, hazards, driving, weather,
# alerts).
# How: escapes every interpolated value, decides between single-alert vs
# multi-alert renders, and concatenates the per-row strings.
# When: called by build_popup_vectorized for every ZCTA on each rebuild
# (or lazily on click when LAZY_ZIP_POPUPS_ENABLED).
# Impact: this is the canonical layout of the popup - any new field needs
# to be plumbed both here and in zip_view_compare_columns to render and
# invalidate cleanly.
build_popup_html_fields <- function(zipcode, county_name, place_name, horizon_label, risk_label,
                                    forecast_temperature_f, forecast_wind_mph, forecast_pop_pct,
                                    alert_event, normalized_risk_score, alert_url, forecast_short,
                                    alert_event_list = NA_character_, alert_url_list = NA_character_,
                                    proximity_boosted = FALSE,
                                    risk_component_summary_text = NA_character_,
                                    risk_type_summary_text = NA_character_,
                                    driving_total_risk = NA_real_, driving_risk_label = NA_character_,
                                    driving_reason_text = NA_character_,
                                    forecast_wind_dir = NA_character_, forecast_wind_dir_degrees = NA_real_,
                                    temperature_pressure_text = NA_character_,
                                    primary_map = DEFAULT_PRIMARY_MAP,
                                    primary_map_score = NA_real_,
                                    primary_map_label = NA_character_) {
  zipcode <- escape_html(zipcode)
  county <- escape_html(county_name %||% "Unknown")
  city <- escape_html(place_name %||% "N/A")
  temp <- if (is.finite(forecast_temperature_f)) sprintf("%.0f°F", forecast_temperature_f) else "N/A"
  wind <- if (is.finite(forecast_wind_mph)) sprintf("%.0f mph", forecast_wind_mph) else "N/A"
  popv <- if (is.finite(forecast_pop_pct)) sprintf("%.0f%%", forecast_pop_pct) else "N/A"
  wind_dir <- escape_html(normalize_wind_direction(forecast_wind_dir) %||% "N/A")
  horizon <- escape_html(horizon_label %||% "Live")
  map_key <- normalize_primary_map(primary_map)
  map_name <- primary_map_display_name(map_key)
  map_score <- safe_numeric(primary_map_score %||% NA_real_)
  if (!is.finite(map_score)) map_score <- safe_numeric(normalized_risk_score %||% 0)
  map_label <- trimws(safe_string(primary_map_label))
  if (!nzchar(map_label)) map_label <- risk_label_from_score(map_score)
  alert_events <- split_alert_field_values(alert_event_list)
  alert_urls <- split_alert_field_values(alert_url_list)
  if (length(alert_events) == 0 && !is.null(alert_event) && !is.na(alert_event) && nzchar(trimws(as.character(alert_event)))) {
    alert_events <- trimws(as.character(alert_event))
  }
  if (length(alert_urls) == 0 && !is.null(alert_url) && !is.na(alert_url) && nzchar(trimws(as.character(alert_url)))) {
    alert_urls <- trimws(as.character(alert_url))
  }
  alert_present <- length(alert_events) > 0
  alert_html <- if (alert_present) alert_field_multi_html(alert_events, normalized_risk_score, alert_urls, forecast_short, risk_label, proximity_boosted) else NULL
  alert_label <- if (length(alert_events) > 1) "Alerts" else "Alert"
  map_hazard <- escape_html(sprintf("%s (%s)", format_score_pct(map_score), map_label))
  env_hazard <- escape_html(sprintf("%s (%s)", format_score_pct(normalized_risk_score), risk_label %||% "Transparent"))
  drive_label <- escape_html(sprintf("%s (%s)", format_score_pct(driving_total_risk), driving_risk_label %||% "Transparent"))
  # `%||%` only catches NULL, not NA — so a stale or partial pipeline
  # that left driving_reason_text as NA_character_ would render as the
  # literal "NA" in the popup ("Driving hazard: NA"). Treat NA / empty
  # string as "All clear." so the popup is always sensible.
  drive_reason_clean <- as.character(driving_reason_text %||% "All clear.")
  if (length(drive_reason_clean) == 0L || is.na(drive_reason_clean) || !nzchar(trimws(drive_reason_clean))) {
    drive_reason_clean <- "All clear."
  }
  drive_reason <- escape_html(drive_reason_clean)
  component_summary <- escape_html(risk_component_summary_text %||% "No material contributors.")
  risk_type_summary <- escape_html(risk_type_summary_text %||% "No material contributors.")
  rows <- c(
    popup_value_row_html("County", county),
    popup_value_row_html("City", city),
    popup_value_row_html("View", escape_html(sprintf("%s (%s)", map_name, horizon))),
    popup_value_row_html("Map hazard", map_hazard),
    popup_value_row_html("Environmental hazard", env_hazard),
    popup_value_row_html("Key contributors", component_summary),
    popup_value_row_html("Risk type", risk_type_summary),
    popup_value_row_html("Driving risk", drive_label),
    popup_value_row_html("Driving hazard", drive_reason),
    popup_value_row_html("Temperature", escape_html(temp)),
    popup_value_row_html("Temperature pressure", escape_html(temperature_pressure_text %||% "N/A")),
    popup_value_row_html("Wind", escape_html(wind)),
    popup_value_row_html("Wind direction", wind_dir),
    popup_value_row_html("Precipitation", escape_html(popv))
  )
  if (!is.null(alert_html)) {
    rows <- c(rows, popup_value_row_html(alert_label, alert_html))
  }
  paste0(
    '<div style="min-width:300px; max-width:320px;">',
    popup_compass_svg_html(forecast_wind_dir, forecast_wind_dir_degrees, forecast_wind_mph),
    sprintf('<div style="font-weight:700; font-size:1rem; margin-bottom:0.35rem; text-align:center;">ZIP %s</div>', zipcode),
    paste(rows, collapse = ""),
    '</div>'
  )
}

# Why: rendering popup HTML row-by-row in R is the slowest part of the
# build; mapply over a single vectorised call reduces overhead considerably.
# What: returns a character vector of HTML strings, one per ZIP row.
# How: pulls each named column off zips with NA-safe defaults, then
# mapply(build_popup_html_fields, ...).
# When: called by the layer builder when popups are eagerly materialised.
# Impact: skipping this path (LAZY popup mode) defers cost to click time;
# any new column must be added to both this caller and the field builder.
build_popup_vectorized <- function(zips) {
  alert_event_list <- if ("alert_event_list" %in% names(zips)) zips$alert_event_list else rep(NA_character_, nrow(zips))
  alert_url_list <- if ("alert_url_list" %in% names(zips)) zips$alert_url_list else rep(NA_character_, nrow(zips))
  temperature_pressure_text <- if ("temperature_pressure_text" %in% names(zips)) zips$temperature_pressure_text else rep(NA_character_, nrow(zips))
  primary_map <- if ("primary_map_key" %in% names(zips)) zips$primary_map_key else rep(DEFAULT_PRIMARY_MAP, nrow(zips))
  primary_map_score <- if ("fill_risk_score" %in% names(zips)) zips$fill_risk_score else zips$normalized_risk_score
  primary_map_label <- if ("display_risk_label" %in% names(zips)) zips$display_risk_label else zips$risk_label
  mapply(
    build_popup_html_fields,
    zipcode = zips$zipcode,
    county_name = zips$county_name,
    place_name = zips$place_name,
    horizon_label = zips$horizon_label,
    risk_label = zips$risk_label,
    forecast_temperature_f = zips$forecast_temperature_f,
    forecast_wind_mph = zips$forecast_wind_mph,
    forecast_pop_pct = zips$forecast_pop_pct,
    alert_event = zips$alert_event,
    normalized_risk_score = zips$normalized_risk_score,
    alert_url = zips$alert_url,
    forecast_short = zips$forecast_short,
    alert_event_list = alert_event_list,
    alert_url_list = alert_url_list,
    proximity_boosted = zips$proximity_boosted,
    risk_component_summary_text = zips$risk_component_summary_text,
    risk_type_summary_text = zips$risk_type_summary_text,
    driving_total_risk = zips$driving_total_risk,
    driving_risk_label = zips$driving_risk_label,
    driving_reason_text = zips$driving_reason_text,
    forecast_wind_dir = zips$forecast_wind_dir,
    forecast_wind_dir_degrees = zips$forecast_wind_dir_degrees,
    temperature_pressure_text = temperature_pressure_text,
    primary_map = primary_map,
    primary_map_score = primary_map_score,
    primary_map_label = primary_map_label,
    SIMPLIFY = TRUE,
    USE.NAMES = FALSE
  )
}

# Why: the legend changes per primary_map and horizon, with custom copy and
# a gradient bar that matches the layer colour palette.
# What: returns a shiny::div tag with title, gradient bar, label markers,
# short copy, and longer detail paragraphs.
# How: switches on primary_map for descriptive copy, computes gamma-shaped
# label positions via risk_scale_position, and uses legend_gradient_style
# for the linear-gradient CSS.
# When: re-rendered whenever the user changes horizon or primary map.
# Impact: a new primary map needs new switch entries here or the legend
# falls back to generic copy; positions tied to RISK_*_MIN constants.
build_legend_html <- function(horizon_key, primary_map = DEFAULT_PRIMARY_MAP) {
  horizon_label <- switch(horizon_key %||% "live", live = "Live", `24h` = "24 hours", `48h` = "48 hours", `72h` = "72 hours", "Live")
  primary_map <- normalize_primary_map(primary_map)
  map_label <- names(PRIMARY_MAP_CHOICES)[match(primary_map, unname(PRIMARY_MAP_CHOICES))]
  if (!nzchar(map_label %||% "")) map_label <- "Normalized environmental risk"
  range_copy <- "Scale: Transparent 0-39, Green 40-69, Yellow 70-87, Red 88-100."
  overlay_copy <- NULL
  detail_copy <- switch(
    primary_map,
    environmental = c(
      "Shows the blended statewide hazard after combining the main family totals into one normalized score.",
      "Use this layer to spot places where multiple families reinforce one another even when no single family dominates."
    ),
    wind = c(
      "Shows wind-driven risk from forecast wind signals plus severe-wind support when convective guidance is active.",
      "Use it to isolate crosswind, gust, and damaging-wind exposure without the other families masking the view."
    ),
    qpf_flood = c(
      "Shows flood-related risk from QPF, flash-flood guidance, river context, and flood-support alerts.",
      "Use it to see where runoff and river impacts are driving the hazard picture even if other families stay quiet."
    ),
    winter = c(
      "Shows winter-weather risk from snow, ice, cold-assisted precipitation, and winter alert support.",
      "Use it to focus on travel and accumulation risk when frozen precipitation is the main concern."
    ),
    fire = c(
      "Shows fire-weather risk from dry, windy, and smoke-linked conditions plus fire-support alerts.",
      "Use it to identify where ignition and spread conditions are elevated even when flood or convective risk is low."
    ),
    convective = c(
      "Shows storm risk from thunderstorm guidance, lightning support, and convective alert support.",
      "Use it to isolate storm-driven hail, severe wind, or tornado-style risk without the flood family dominating the map."
    ),
    heat = c(
      "Shows heat-related risk from official heat products, forecast heat stress, and supportive UV signal.",
      "Use it to see where apparent heat is driving the hazard picture rather than wind, flood, or winter impacts."
    ),
    cold = c(
      "Shows cold-stress risk from forecast cold, winter support, and cold-specific alert support.",
      "Use it to isolate dangerous chill and cold exposure even when snowfall itself is not the main hazard."
    ),
    air = c(
      "Shows air-quality and smoke-related risk from AirNow guidance plus smoke, dust, or air-quality alert support.",
      "This layer is where ozone, PM2.5, PM10, smoke, and dust conditions appear when they are elevated enough to matter."
    ),
    radiation = c(
      "Shows radiation and UV-related risk from ionizing-signal inputs blended with UV exposure support.",
      "Use it to isolate radiation-driven hazards that are not visible in the other weather-oriented families."
    ),
    seismic = c(
      "Shows earthquake-related risk from seismic activity and seismic alert support.",
      "Use it to isolate ground-shaking risk without the environmental score being dominated by weather families."
    ),
    c(
      "Shows the selected family on the shared risk scale.",
      "Use it to isolate that family from the combined environmental view."
    )
  )
  risk_copy <- switch(
    primary_map,
    environmental = sprintf("Combined family risk by ZIP. %s", range_copy),
    wind = sprintf("Wind family risk by ZIP. %s", range_copy),
    qpf_flood = sprintf("Flood family risk by ZIP. %s", range_copy),
    winter = sprintf("Winter family risk by ZIP. %s", range_copy),
    fire = sprintf("Fire family risk by ZIP. %s", range_copy),
    convective = sprintf("Storm-family risk by ZIP. %s", range_copy),
    heat = sprintf("Heat family risk by ZIP. %s", range_copy),
    cold = sprintf("Cold family risk by ZIP. %s", range_copy),
    air = sprintf("Air family risk by ZIP. %s", range_copy),
    radiation = sprintf("Radiation family risk by ZIP. %s", range_copy),
    seismic = sprintf("Seismic family risk by ZIP. %s", range_copy),
    sprintf("ZIP family risk. %s", range_copy)
  )
  label_positions <- c(
    Transparent = 100 * risk_scale_position(RISK_GREEN_MIN / 2),
    Green = 100 * risk_scale_position((RISK_GREEN_MIN + RISK_YELLOW_MIN) / 2),
    Yellow = 100 * risk_scale_position((RISK_YELLOW_MIN + RISK_RED_MIN) / 2),
    Red = 100 * risk_scale_position((RISK_RED_MIN + 1) / 2)
  )
  legend_bar_style <- legend_gradient_style()
  shiny::div(
    class = "risk-legend-card",
    style = "background:#ffffff !important; opacity:1 !important;",
    shiny::div(class = "risk-legend-title", sprintf("%s (%s)", map_label, horizon_label)),
    if (is.null(overlay_copy)) shiny::div(class = "risk-legend-bar", style = legend_bar_style),
    if (is.null(overlay_copy)) shiny::div(
      class = "risk-legend-labels",
      lapply(
        seq_along(label_positions),
        function(i) {
          shiny::tags$span(
            class = "risk-legend-label",
            style = sprintf("left: %.1f%%;", unname(label_positions[i])),
            names(label_positions)[i]
          )
        }
      )
    ),
    shiny::div(class = "risk-legend-copy", overlay_copy %||% risk_copy),
    shiny::div(
      class = "risk-legend-detail",
      lapply(
        detail_copy,
        function(txt) shiny::tags$p(txt)
      )
    )
  )
}

# Why: notice cards in the sidebar need a single (score, label, css class)
# triple derived from the alert tier, not the raw blended score.
# What: returns a list(score, raw_score, label, class) for use by
# build_notice_cards.
# How: computes raw score via score_nws_alert and tier via
# alert_notification_level; clamps display_score to a tier-specific value
# (red/yellow/green) so cards always use the tier colour, and chooses the
# CSS class accordingly.
# When: called per notice while building the card stack in build_notice_cards.
# Impact: shifting the display_score thresholds here re-skins the entire
# notice list; raw_score is preserved for sorting if needed.
notice_card_profile <- function(event, severity, urgency = NULL, certainty = NULL) {
  raw_score <- safe_numeric(score_nws_alert(event, severity, urgency, certainty))
  if (!is.finite(raw_score)) raw_score <- 0
  level <- alert_notification_level(event)
  display_score <- ifelse(
    level %in% "alert",
    min(1, RISK_RED_MIN + 0.001),
    ifelse(level %in% "warning", RISK_YELLOW_MIN, ifelse(level %in% "watch", RISK_GREEN_MIN, raw_score))
  )
  label <- if (level %in% c("alert", "warning", "watch")) {
    switch(level, alert = "Red", warning = "Yellow", watch = "Green", risk_label_from_score(display_score))
  } else {
    risk_label_from_score(display_score)
  }
  risk_class <- switch(
    label,
    Green = "notice-card-risk-green",
    Yellow = "notice-card-risk-yellow",
    Red = "notice-card-risk-red",
    "notice-card-risk-transparent"
  )
  list(
    score = display_score,
    raw_score = raw_score,
    label = label,
    class = paste("notice-card", risk_class)
  )
}
