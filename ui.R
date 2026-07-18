# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: wizeman555@gmail.com
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

library(shiny)
library(leaflet)

bootstrapPage(
  tags$head(
    # Shared cross-platform chrome (macOS Safari, iOS/iPadOS Safari + WKWebView
    # home-screen app). Without the viewport tag, mobile Safari renders at a
    # 980px desktop width zoomed out; viewport-fit=cover lets the layout paint
    # under the notch/home-indicator while safe-area insets (styles.css) keep
    # controls clear of them.
    tags$meta(charset = "utf-8"),
    tags$meta(
      name = "viewport",
      content = "width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=5"
    ),
    # Standalone home-screen app on iOS/iPadOS; match the map chrome colour.
    tags$meta(name = "apple-mobile-web-app-capable", content = "yes"),
    tags$meta(name = "mobile-web-app-capable", content = "yes"),
    tags$meta(name = "apple-mobile-web-app-status-bar-style", content = "black-translucent"),
    tags$meta(name = "apple-mobile-web-app-title", content = "FLOWS"),
    tags$meta(name = "theme-color", content = "#0b0e12"),
    tags$meta(name = "color-scheme", content = "light dark"),
    # Stop iOS from auto-linkifying ZIPs/route text as phone numbers.
    tags$meta(name = "format-detection", content = "telephone=no"),
    includeCSS("styles.css"),
    includeScript("gomap.js")
  ),
  div(
    class = "app-shell",
    div(id = "map-shell", leafletOutput("map", width = "100%", height = "100%")),
    div(
      class = "notice-stack-shell",
      uiOutput("warning_cards")
    ),
    div(
      class = "control-shell",
      div(
        id = "map_progress_ui",
        div(
          class = "map-progress-attached",
          div(
            class = "map-progress-track",
            div(class = "map-progress-bar", style = "width: 100%;")
          ),
          div(class = "map-progress-detail", "Map ready.")
        )
      ),
      div(
        class = "timeline-segmented",
        radioButtons(
          "time_horizon",
          label = NULL,
          choices = c("Live" = "live", "24hrs" = "24h", "48hrs" = "48h", "72hrs" = "72h"),
          selected = "live",
          inline = TRUE
        )
      ),
      tags$details(
        class = "filter-details",
        tags$summary(div(class = "filter-summary-text", "Map Filter")),
        div(
          class = "filter-panel",
          div(class = "filter-section-title", "Primary map"),
          radioButtons(
            "primary_map",
            label = NULL,
            choiceNames = lapply(names(PRIMARY_MAP_CHOICES), function(lbl) tags$span(class = "filter-option-label", lbl)),
            choiceValues = unname(PRIMARY_MAP_CHOICES),
            selected = DEFAULT_PRIMARY_MAP
          ),
          checkboxGroupInput(
            "reference_layers",
            label = NULL,
            choiceNames = lapply(names(REFERENCE_LAYER_CHOICES), function(lbl) tags$span(class = "filter-option-label", lbl)),
            choiceValues = unname(REFERENCE_LAYER_CHOICES),
            selected = DEFAULT_REFERENCE_LAYERS
          ),
          div(class = "filter-section-footnote", "Reference layers toggle county outlines, ZIP outlines, and the existing live road-risk overlay. Primary maps switch between the normalized environmental view and its main risk families.")
        )
      )
    ),

    div(
      class = "route-shell",
      div(
      class = "route-card",
        div(
          class = "route-card-search-section",
          div(class = "route-card-section-label", "Search"),
          div(
            class = "search-inner route-card-search",
            textInput("search_query", NULL, placeholder = "Search by ZIP code, county name, or city name"),
            actionButton("search_go", "Search", class = "search-button")
          )
        ),
        div(class = "route-card-divider"),
        div(class = "route-card-title", "Route planner"),
        div(
          class = "route-fields-row",
          div(class = "route-field", textInput("route_start", NULL, placeholder = "Source ZIP, county, or city")),
          div(class = "route-field", textInput("route_end", NULL, placeholder = "Destination ZIP, county, or city"))
        ),
        actionButton("route_go", "Plan route", class = "route-button")
      )
    ),
    uiOutput("route_summary_shell"),
    div(
      class = "legend-shell",
      uiOutput("risk_legend")
    )
  )
)
