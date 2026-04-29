# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

library(shiny)
library(leaflet)
library(sf)

shinyServer(function(input, output, session) {
  ALERT_POLL_MILLISECONDS <- max(600000, ALERT_TTL_SECONDS * 1000)
  LATITUDE_BAND_RENDER_DELAY_MS <- 120L

  current_hover_notice <- reactiveVal("")
  current_rendered <- reactiveVal(data.frame(zipcode = character(), render_signature = character(), stringsAsFactors = FALSE))
  current_rendered_roads <- reactiveVal(data.frame(road_id = character(), render_signature = character(), stringsAsFactors = FALSE))
  current_horizon_loaded <- reactiveVal("")
  current_primary_loaded <- reactiveVal("")
  current_road_horizon_loaded <- reactiveVal("")
  current_route_result <- reactiveVal(list(message = "", routes = list(), start_point = NULL, end_point = NULL))
  current_polygons_snapshot <- reactiveVal(NULL)
  current_roads_snapshot <- reactiveVal(NULL)
  current_route_segments_snapshot <- reactiveVal(NULL)
  route_summary_open <- reactiveVal(FALSE)

  push_progress <- function(value = NULL, detail = NULL) {
    payload <- list(
      value = if (is.null(value)) NA_real_ else pmax(0, pmin(100, suppressWarnings(as.numeric(value)) * 100)),
      detail = if (is.null(detail)) "" else as.character(detail)
    )
    session$sendCustomMessage("updateProgressBar", payload)
    invisible(NULL)
  }
  reset_progress <- function() {
    session$sendCustomMessage("updateProgressBar", list(value = 100, detail = "Map ready.", reset = TRUE))
    invisible(NULL)
  }
  dismissed_notice_ids <- reactiveVal(character(0))
  last_map_payload <- reactiveVal(NULL)
  last_map_payload_key <- reactiveVal("")
  startup_snapshot_served <- reactiveVal(FALSE)
  prefetch_queue <- reactiveVal(c("zip_places", "live_startup_payload"))
  pending_band_payload <- reactiveVal(NULL)
  pending_band_ids <- reactiveVal(integer(0))
  pending_band_index <- reactiveVal(0L)

  empty_route_result <- function(message = "") {
    list(message = message, routes = list(), start_point = NULL, end_point = NULL)
  }

  current_alert_payload <- reactivePoll(
    ALERT_POLL_MILLISECONDS,
    session,
    checkFunc = function() {
      payload <- tryCatch(fetch_wisconsin_alerts(force_refresh = FALSE, timeout_seconds = 8L, max_tries = 1L, allow_stale = TRUE), error = function(e) list(etag = paste0("alert-error-", as.integer(Sys.time()) %/% ALERT_TTL_SECONDS)))
      as.character(payload$etag %||% "")
    },
    valueFunc = function() {
      tryCatch(fetch_wisconsin_alerts(force_refresh = FALSE, timeout_seconds = 8L, max_tries = 1L, allow_stale = TRUE), error = function(e) list(alerts_sf = empty_alert_sf(), alerts_df = data.frame(), notices = data.frame(), alert_zip_map = list(), notice_zip_map = list(), etag = paste0("alert-error-", as.integer(Sys.time()) %/% ALERT_TTL_SECONDS)))
    }
  )

  current_horizon_alert_payload <- reactive({
    filter_alert_payload_for_horizon(
      current_alert_payload(),
      horizon_key = input$time_horizon %||% "live"
    )
  })

  external_bundle_generation <- reactivePoll(
    4000,
    session,
    checkFunc = function() {
      latest_external_bundle_snapshot_mtime()
    },
    valueFunc = function() {
      latest_external_bundle_snapshot_mtime()
    }
  )

  output$map <- renderLeaflet({
    border_states <- tryCatch(load_border_states(), error = function(e) NULL)
    fit_box <- c(
      xmin = wi_bounds$west - 0.90,
      ymin = wi_bounds$south - 0.78,
      xmax = wi_bounds$east + 0.82,
      ymax = wi_bounds$north + 0.78
    )
    wi_center_lat <- (wi_bounds$south + wi_bounds$north) / 2
    init_box <- c(
      xmin = wi_bounds$west,
      ymin = wi_center_lat - 1.0,
      xmax = wi_bounds$east,
      ymax = wi_center_lat + 1.0
    )
    tile_bounds <- list(c(fit_box[["ymin"]], fit_box[["xmin"]]), c(fit_box[["ymax"]], fit_box[["xmax"]]))
    if (!is.null(border_states) && nrow(border_states) > 0) {
      view_box <- sf::st_as_sfc(sf::st_bbox(fit_box, crs = sf::st_crs(4326)))
      border_states <- tryCatch(suppressWarnings(sf::st_intersection(border_states, view_box)), error = function(e) border_states)
    }

    map <- leaflet(options = leafletOptions(zoomControl = FALSE, minZoom = 6, maxZoom = 13, preferCanvas = TRUE, worldCopyJump = FALSE, zoomSnap = 0.25, zoomDelta = 0.5)) %>%
      addMapPane("base_reference_pane", zIndex = 380) %>%
      addMapPane("risk_polygons_pane", zIndex = 410) %>%
      addMapPane("roads_overlay_pane", zIndex = 430) %>%
      addMapPane("route_pane", zIndex = 450) %>%
      addProviderTiles(
        providers$Esri.WorldTopoMap,
        group = "cartographic_base",
        options = providerTileOptions(noWrap = TRUE, updateWhenIdle = TRUE, keepBuffer = 1, bounds = tile_bounds)
      )
    if (!is.null(border_states) && nrow(border_states) > 0) {
      map <- map %>%
        addPolygons(
          data = border_states,
          group = "border_state_fill",
          stroke = FALSE,
          fillColor = "transparent",
          fillOpacity = 0,
          smoothFactor = 0.2,
          options = pathOptions(pane = "base_reference_pane")
        ) %>%
        addPolylines(
          data = suppressWarnings(sf::st_boundary(sf::st_geometry(border_states))),
          group = "border_state_outline",
          color = "#b4bcc5",
          weight = 1.2,
          opacity = 0.9,
          smoothFactor = 0.2,
          options = pathOptions(pane = "base_reference_pane")
        )
    }
    map <- map %>%
      addPolygons(
        data = sf::st_sf(id = 1L, geometry = sf::st_sfc(wi_state_geom, crs = 4326)),
        group = "wi_state_fill",
        stroke = FALSE,
        fillColor = "transparent",
        fillOpacity = 0,
        smoothFactor = 0.2,
        options = pathOptions(pane = "base_reference_pane")
      ) %>%
      addPolylines(
        data = wi_state_outline,
        group = "wi_outline",
        color = "#4f5965",
        weight = 1.9,
        opacity = 1,
        smoothFactor = 0.2,
        options = pathOptions(pane = "base_reference_pane")
      ) %>%
      addPolygons(
        data = wi_counties,
        group = "county_fallback",
        fillColor = "transparent",
        fillOpacity = 0,
        color = "#8a8f98",
        weight = 1.05,
        opacity = 0.85,
        smoothFactor = 0.2,
        label = ~NAME,
        options = pathOptions(pane = "base_reference_pane")
      ) %>%
      addPolylines(
        data = wi_zctas,
        group = "zip_outline",
        color = "#d6dbe1",
        weight = 0.65,
        opacity = 0.9,
        smoothFactor = 0.15,
        options = pathOptions(pane = "base_reference_pane")
      )
    map %>%
      fitBounds(init_box[["xmin"]], init_box[["ymin"]], init_box[["xmax"]], init_box[["ymax"]]) %>%
      setMaxBounds(fit_box[["xmin"]], fit_box[["ymin"]], fit_box[["xmax"]], fit_box[["ymax"]])
  })

  primary_map <- reactive({
    normalize_primary_map(input$primary_map %||% DEFAULT_PRIMARY_MAP)
  })

  reference_layers <- reactive({
    unique(as.character(input$reference_layers %||% DEFAULT_REFERENCE_LAYERS))
  })

  selected_features <- reactive({
    primary_map_features(primary_map())
  })

  observe({
    layers <- reference_layers()
    proxy <- leafletProxy("map")
    if ("county_outline" %in% layers) proxy <- proxy %>% showGroup("county_fallback") else proxy <- proxy %>% hideGroup("county_fallback")
    if ("zip_outline" %in% layers) proxy <- proxy %>% showGroup("zip_outline") else proxy <- proxy %>% hideGroup("zip_outline")
    if ("road_reference" %in% layers) proxy <- proxy %>% showGroup("road_hazard_overlay") else proxy <- proxy %>% hideGroup("road_hazard_overlay")
    invisible(proxy)
  })

  output$warning_cards <- renderUI({
    payload <- current_horizon_alert_payload()
    dismissed <- unique(as.character(dismissed_notice_ids() %||% character(0)))
    if (length(dismissed) > 0 && nrow(payload$notices %||% data.frame()) > 0) {
      keep_idx <- !(as.character(payload$notices$alert_id %||% character(0)) %in% dismissed)
      payload$notices <- payload$notices[keep_idx, , drop = FALSE]
      notice_ids <- as.character(payload$notices$alert_id %||% character(0))
      payload$notice_zip_map <- (payload$notice_zip_map %||% list())[notice_ids]
      names(payload$notice_zip_map) <- notice_ids
    }
    build_notice_cards(clickable = TRUE, hover_enabled = TRUE, payload = payload)
  })

  output$risk_legend <- renderUI({
    build_legend_html(input$time_horizon %||% "live", primary_map())
  })

  output$route_summary <- renderUI({
    render_route_summary_ui(current_route_result())
  })

  output$route_details <- renderUI({
    render_route_details_ui(current_route_result(), suppressWarnings(as.numeric(input$route_choice %||% NA)))
  })

  output$route_summary_shell <- renderUI({
    res <- current_route_result()
    if (!isTRUE(route_summary_open()) || is.null(res) || length(res$routes %||% list()) == 0) return(NULL)
    shiny::div(
      class = "route-summary-shell",
      shiny::div(
        class = "route-summary-panel",
        shiny::div(
          class = "route-summary-header",
          shiny::div(class = "route-summary-panel-title", "Route options"),
          actionButton("route_close", "X", class = "route-close-button")
        ),
        shiny::uiOutput("route_summary"),
        shiny::uiOutput("route_details")
      )
    )
  })

  current_map_payload <- reactive({
    route_interaction_active <- isolate(
      isTRUE(route_summary_open()) ||
        nzchar(trimws(input$route_start %||% "")) ||
        nzchar(trimws(input$route_end %||% ""))
    )
    if (!isTRUE(route_interaction_active)) {
      external_bundle_generation()
    }
    horizon <- input$time_horizon %||% "live"
    current_primary <- primary_map()
    risk_primary <- current_primary
    features <- selected_features()
    include_transport <- TRUE
    alert_payload <- NULL
    external_bundle_token <- external_bundle_cache_token(horizon, features, include_transport = include_transport)
    payload_key <- paste(horizon, risk_primary, paste(features, collapse = ","), include_transport, external_bundle_token, sep = "::")
    map_label <- names(PRIMARY_MAP_CHOICES)[match(current_primary, unname(PRIMARY_MAP_CHOICES))]
    if (!nzchar(map_label %||% "")) map_label <- "Current map"
    cached_payload <- isolate(last_map_payload())
    cached_payload_key <- isolate(last_map_payload_key())
    if (!is.null(cached_payload) && identical(cached_payload_key, payload_key)) {
      return(cached_payload)
    }

    progress_value <- 0
    progress_update <- function(value = NULL, detail = NULL) {
      if (!is.null(value) && is.finite(value)) {
        progress_value <<- max(progress_value, pmin(1, as.numeric(value)))
      }
      push_progress(progress_value, detail %||% map_label)
      invisible(NULL)
    }
    on.exit({
      reset_progress()
    }, add = TRUE)
    tryCatch({
      snapshot_served <- isolate(isTRUE(startup_snapshot_served()))
      if (identical(horizon, "live") && identical(risk_primary, DEFAULT_PRIMARY_MAP) && !snapshot_served) {
        snapshot <- tryCatch(load_startup_map_snapshot(horizon_key = horizon, primary_map = risk_primary), error = function(e) NULL)
        if (!is.null(snapshot) && !is.null(snapshot$polys) && inherits(snapshot$polys, "sf") && nrow(snapshot$polys) > 0) {
          startup_snapshot_served(TRUE)
          last_map_payload(snapshot)
          last_map_payload_key(payload_key)
          return(snapshot)
        }
      }
      progress_update(0.01, sprintf("Loading %s view with synchronized transportation overlay.", switch(horizon, live = "live", `24h` = "24-hour", `48h` = "48-hour", `72h` = "72-hour", "live")))
      if (identical(horizon, "live")) {
        progress_update(0.03, "Refreshing live Wisconsin alerts and official transportation conditions.")
        alert_payload <- fetch_wisconsin_alerts(force_refresh = FALSE, timeout_seconds = 8L, max_tries = 1L, allow_stale = TRUE)
      }
      polys <- build_risk_polygons(
        horizon,
        features,
        alert_payload = alert_payload,
        include_transport = include_transport,
        progress = progress_update,
        primary_map = risk_primary
      )
      progress_update(0.98, "Preparing synchronized color-coded road overlay.")
      roads <- build_driving_roads_overlay(polys, horizon)
      progress_update(0.995, "Warming route graph cache for faster route planning.")
      route_segments <- tryCatch(build_route_segments(polys, horizon, roads_overlay = roads), error = function(e) NULL)
      progress_update(1, "Map ready.")
      payload <- list(polys = polys, roads = roads, route_segments = route_segments, primary_map = current_primary, map_label = map_label, horizon = horizon)
      snapshot_payload <- payload
      snapshot_payload$route_segments <- NULL
      try(save_startup_map_snapshot(snapshot_payload, horizon_key = horizon, primary_map = risk_primary), silent = TRUE)
      last_map_payload(payload)
      last_map_payload_key(payload_key)
      try(purge_inactive_map_caches(horizon, risk_primary), silent = TRUE)
      payload
    }, error = function(e) {
      fallback <- last_map_payload()
      showNotification(paste(map_label, "view failed:", conditionMessage(e)), type = "error", duration = 8)
      if (!is.null(fallback)) return(fallback)
      stop(e)
    })
  })

  current_polygons <- reactive({
    payload <- current_map_payload()
    payload$polys
  })


  recompute_route_result <- function() {
    progress_value <- 0
    route_progress_update <- function(value = NULL, detail = NULL) {
      if (!is.null(value) && is.finite(value)) {
        progress_value <<- max(progress_value, pmin(1, as.numeric(value)))
      }
      push_progress(progress_value, detail %||% "Route planner")
      invisible(NULL)
    }
    on.exit({
      reset_progress()
    }, add = TRUE)

    start_query <- input$route_start %||% ""
    end_query <- input$route_end %||% ""
    route_progress_update(0.02, "Reading the source and destination you typed in.")
    if (!nzchar(trimws(start_query)) || !nzchar(trimws(end_query))) {
      empty <- empty_route_result()
      current_route_result(empty)
      return(invisible(empty))
    }
    route_progress_update(0.06, "Looking up your start point in the Wisconsin index.")
    route_progress_update(0.10, "Looking up your destination in the Wisconsin index.")
    route_progress_update(0.14, "Borrowing the live Wisconsin map snapshot.")
    polys <- tryCatch(current_polygons_snapshot(), error = function(e) NULL)
    if (is.null(polys) || nrow(polys) == 0) {
      out <- empty_route_result("Route planning could not use the current map state yet. Wait for the map to finish loading and try again.")
      current_route_result(out)
      return(invisible(out))
    }
    route_progress_update(0.20, "Reusing the cached road graph for the selected timeline.")
    route_segments <- tryCatch(current_route_segments_snapshot(), error = function(e) NULL)
    route_progress_update(0.28, "Asking the routing service for path candidates.")
    res <- tryCatch(
      plan_route_options(
        start_query,
        end_query,
        polys,
        input$time_horizon %||% "live",
        route_segments = route_segments,
        progress = route_progress_update
      ),
      error = function(e) empty_route_result(paste("Route planning failed:", conditionMessage(e)))
    )
    if (length(res$routes %||% list()) == 0) {
      res <- empty_route_result(res$message %||% "No route could be computed from the current Wisconsin road graph.")
    }
    route_progress_update(0.95, "Annotating routes with hazard exposure.")
    route_progress_update(1, "Routes ready.")
    current_route_result(res)
    invisible(res)
  }

  render_route_result_on_map <- function(res, fit_view = TRUE, selected_rank = NULL) {
    proxy <- leafletProxy("map") %>% clearGroup("route_paths") %>% clearGroup("route_points")
    if (is.null(res) || length(res$routes) == 0) return(invisible(NULL))
    roads_snapshot <- current_roads_snapshot()
    if (!is.finite(suppressWarnings(as.numeric(selected_rank)))) {
      selected_rank <- suppressWarnings(as.numeric(res$routes[[1]]$summary$route_rank %||% 1L))
    }
    route_ranks <- vapply(res$routes, function(rt) suppressWarnings(as.numeric(rt$summary$route_rank %||% NA_real_)), numeric(1))
    route_order <- order(route_ranks == selected_rank)
    for (idx in route_order) {
      rt <- res$routes[[idx]]
      rsf <- route_display_sf(rt, roads_snapshot)
      if (nrow(rsf) == 0) next
      is_selected <- identical(suppressWarnings(as.numeric(rt$summary$route_rank %||% NA_real_)), selected_rank)
      route_opacity <- if (is_selected) (rsf$route_opacity[1] %||% 0.95) else max(0.32, (rsf$route_opacity[1] %||% 0.95) * 0.60)
      route_weight <- if (is_selected) ((rsf$route_weight[1] %||% 5.0) + 1.1) else max(2.8, (rsf$route_weight[1] %||% 5.0) - 1.1)
      proxy <- proxy %>% addPolylines(
        data = rsf,
        group = "route_paths",
        color = rsf$route_color[1],
        opacity = route_opacity,
        weight = route_weight,
        popup = ~sprintf("<strong>%s</strong><br/>%s", route_name, escape_html(reason_text)),
        label = ~route_name,
        smoothFactor = 0.1,
        options = pathOptions(pane = "route_pane")
      )
    }
    pts <- list()
    if (!is.null(res$start_point)) pts[[length(pts) + 1L]] <- data.frame(lng = res$start_point$lon, lat = res$start_point$lat, label = paste0("Start: ", res$start_point$label), stringsAsFactors = FALSE)
    if (!is.null(res$end_point)) pts[[length(pts) + 1L]] <- data.frame(lng = res$end_point$lon, lat = res$end_point$lat, label = paste0("Destination: ", res$end_point$label), stringsAsFactors = FALSE)
    if (length(pts) > 0) {
      pt_df <- dplyr::bind_rows(pts)
      proxy <- proxy %>% addCircleMarkers(
        data = pt_df,
        lng = ~lng,
        lat = ~lat,
        group = "route_points",
        radius = 7,
        stroke = TRUE,
        color = "#111111",
        weight = 2,
        fillColor = "#ffffff",
        fillOpacity = 1,
        label = ~label,
        options = pathOptions(pane = "route_pane")
      )
    }
    route_boxes <- lapply(res$routes, function(rt) {
      rsf <- route_display_sf(rt, roads_snapshot)
      tryCatch(sf::st_bbox(rsf), error = function(e) NULL)
    })
    route_boxes <- Filter(Negate(is.null), route_boxes)
    if (isTRUE(fit_view) && length(route_boxes) > 0) {
      xmin <- min(vapply(route_boxes, function(bb) bb[["xmin"]], numeric(1)), na.rm = TRUE)
      ymin <- min(vapply(route_boxes, function(bb) bb[["ymin"]], numeric(1)), na.rm = TRUE)
      xmax <- max(vapply(route_boxes, function(bb) bb[["xmax"]], numeric(1)), na.rm = TRUE)
      ymax <- max(vapply(route_boxes, function(bb) bb[["ymax"]], numeric(1)), na.rm = TRUE)
      proxy %>% fitBounds(xmin, ymin, xmax, ymax)
    }
    invisible(NULL)
  }

  observeEvent(input$route_go, {
    res <- recompute_route_result()
    if (length(res$routes %||% list()) == 0) {
      route_summary_open(FALSE)
      leafletProxy("map") %>% clearGroup("route_paths") %>% clearGroup("route_points")
      if (nzchar(trimws(res$message %||% ""))) {
        showNotification(res$message, type = "warning", duration = 6)
      }
      return(invisible(NULL))
    }
    route_summary_open(TRUE)
    render_route_result_on_map(res, fit_view = TRUE, selected_rank = suppressWarnings(as.numeric(input$route_choice %||% NA)))
  }, ignoreInit = TRUE)

  observeEvent(input$time_horizon, {
    if (!isTRUE(route_summary_open()) || length(current_route_result()$routes %||% list()) == 0) {
      leafletProxy("map") %>% clearGroup("route_paths") %>% clearGroup("route_points")
      return(invisible(NULL))
    }
    route_summary_open(FALSE)
    current_route_result(empty_route_result())
    leafletProxy("map") %>% clearGroup("route_paths") %>% clearGroup("route_points")
    showNotification("Timeline changed. Press Plan route again to evaluate the selected forecast horizon.", type = "message", duration = 5)
  }, ignoreInit = TRUE)

  observeEvent(input$route_choice, {
    if (!isTRUE(route_summary_open()) || length(current_route_result()$routes %||% list()) == 0) return(invisible(NULL))
    render_route_result_on_map(current_route_result(), fit_view = FALSE, selected_rank = suppressWarnings(as.numeric(input$route_choice %||% NA)))
  }, ignoreInit = TRUE)

  observeEvent(input$route_close, {
    route_summary_open(FALSE)
    current_route_result(empty_route_result())
    leafletProxy("map") %>% clearGroup("route_paths") %>% clearGroup("route_points")
  }, ignoreInit = TRUE)


  update_risk_layer <- function(polys, full_redraw = FALSE) {
    req(polys)
    horizon <- input$time_horizon %||% "live"
    current_primary <- primary_map()
    prev <- current_rendered()
    proxy <- leafletProxy("map")

    if (!primary_map_shows_polygons(current_primary)) {
      proxy %>% clearGroup("risk_polygons")
      current_rendered(data.frame(zipcode = character(), render_signature = character(), stringsAsFactors = FALSE))
      current_horizon_loaded(horizon)
      current_primary_loaded(current_primary)
      return(invisible(TRUE))
    }

    if (isTRUE(full_redraw) || !identical(current_horizon_loaded(), horizon) || !identical(current_primary_loaded(), current_primary) || nrow(prev) == 0) {
      proxy <- proxy %>% clearGroup("risk_polygons")
      proxy <- proxy %>% addPolygons(
        data = polys,
        group = "risk_polygons",
        layerId = ~zipcode,
        fillColor = ~risk_fill_rgba,
        fillOpacity = 1,
        color = "transparent",
        weight = 0,
        opacity = 0,
        smoothFactor = 0.2,
        popup = if (isTRUE(LAZY_ZIP_POPUPS_ENABLED)) NULL else ~popup_label,
        label = NULL,
        options = pathOptions(pane = "risk_polygons_pane")
      )
      current_rendered(sf::st_drop_geometry(polys[, c("zipcode", "render_signature")]))
      current_horizon_loaded(horizon)
      current_primary_loaded(current_primary)
      return(invisible(TRUE))
    }

    curr <- sf::st_drop_geometry(polys[, c("zipcode", "render_signature")])
    merged <- merge(curr, prev, by = "zipcode", all = TRUE, suffixes = c("_new", "_old"))
    changed_ids <- merged$zipcode[is.na(merged$render_signature_old) | is.na(merged$render_signature_new) | merged$render_signature_new != merged$render_signature_old]

    if (length(changed_ids) > 0) {
      changed_polys <- polys[polys$zipcode %in% changed_ids, ]
      if (nrow(changed_polys) > 0) {
        proxy <- proxy %>% removeShape(layerId = changed_polys$zipcode)
        proxy <- proxy %>% addPolygons(
          data = changed_polys,
          group = "risk_polygons",
          layerId = ~zipcode,
          fillColor = ~risk_fill_rgba,
          fillOpacity = 1,
          color = "transparent",
          weight = 0,
          opacity = 0,
          smoothFactor = 0.2,
          popup = if (isTRUE(LAZY_ZIP_POPUPS_ENABLED)) NULL else ~popup_label,
          label = NULL,
          options = pathOptions(pane = "risk_polygons_pane")
        )
      }
      current_rendered(curr)
    }

    current_horizon_loaded(horizon)
    current_primary_loaded(current_primary)
    invisible(TRUE)
  }

  add_risk_polygons_to_proxy <- function(proxy, polys) {
    if (is.null(polys) || !inherits(polys, "sf") || nrow(polys) == 0) return(proxy)
    proxy %>% addPolygons(
      data = polys,
      group = "risk_polygons",
      layerId = ~zipcode,
      fillColor = ~risk_fill_rgba,
      fillOpacity = 1,
      color = "transparent",
      weight = 0,
      opacity = 0,
      smoothFactor = 0.2,
      popup = if (isTRUE(LAZY_ZIP_POPUPS_ENABLED)) NULL else ~popup_label,
      label = NULL,
      options = pathOptions(pane = "risk_polygons_pane")
    )
  }

  ordered_latitude_bands <- function(polys) {
    if (is.null(polys) || !inherits(polys, "sf") || nrow(polys) == 0 || !"lat_band" %in% names(polys)) return(integer(0))
    bands <- suppressWarnings(as.integer(polys$lat_band))
    bands <- sort(unique(bands[is.finite(bands)]), decreasing = TRUE)
    as.integer(bands)
  }

  schedule_banded_map_render <- function(payload) {
    if (is.null(payload) || is.null(payload$polys) || !inherits(payload$polys, "sf") || nrow(payload$polys) == 0) return(invisible(FALSE))
    bands <- ordered_latitude_bands(payload$polys)
    if (length(bands) == 0) {
      current_polygons_snapshot(payload$polys)
      current_route_segments_snapshot(payload$route_segments %||% tryCatch(build_route_segments(payload$polys, payload$horizon %||% (input$time_horizon %||% "live"), roads_overlay = payload$roads), error = function(e) NULL))
      update_risk_layer(payload$polys, full_redraw = TRUE)
      roads <- payload$roads
      current_roads_snapshot(roads)
      update_road_layer(roads, primary_map_key = payload$primary_map %||% DEFAULT_PRIMARY_MAP, full_redraw = TRUE)
      return(invisible(TRUE))
    }
    current_polygons_snapshot(payload$polys)
    current_roads_snapshot(payload$roads)
    current_route_segments_snapshot(payload$route_segments %||% tryCatch(build_route_segments(payload$polys, payload$horizon %||% (input$time_horizon %||% "live"), roads_overlay = payload$roads), error = function(e) NULL))
    current_rendered(data.frame(zipcode = character(), render_signature = character(), stringsAsFactors = FALSE))
    current_rendered_roads(data.frame(road_id = character(), render_signature = character(), stringsAsFactors = FALSE))
    current_horizon_loaded("")
    current_primary_loaded("")
    current_road_horizon_loaded("")
    pending_band_payload(payload)
    pending_band_ids(bands)
    pending_band_index(0L)
    push_progress(0, sprintf("Rendering Wisconsin band %d of %d from north to south.", 1L, length(bands)))
    invisible(TRUE)
  }

  update_road_layer <- function(roads, primary_map_key = DEFAULT_PRIMARY_MAP, full_redraw = FALSE) {
    proxy <- leafletProxy("map")
    road_pane <- "roads_overlay_pane"
    road_options <- pathOptions(pane = road_pane, interactive = FALSE)

    if (is.null(roads) || !inherits(roads, "sf") || nrow(roads) == 0) {
      proxy %>% clearGroup("road_hazard_overlay")
      current_rendered_roads(data.frame(road_id = character(), render_signature = character(), stringsAsFactors = FALSE))
      current_road_horizon_loaded(input$time_horizon %||% "live")
      return(invisible(TRUE))
    }

    roads$render_signature <- paste(
      roads$road_id,
      roads$road_color,
      sprintf("%.3f", suppressWarnings(as.numeric(roads$road_opacity %||% 0))),
      sprintf("%.3f", suppressWarnings(as.numeric(roads$road_weight %||% 0))),
      ifelse(is.na(roads$driving_risk_label), "", roads$driving_risk_label),
      ifelse(is.na(roads$driving_reason_text), "", roads$driving_reason_text),
      ifelse(is.na(roads$road_source), "", roads$road_source),
      ifelse(is.na(roads$official_cause_text), "", roads$official_cause_text),
      ifelse(is.na(roads$dominant_zip), "", roads$dominant_zip),
      sep = "|"
    )

    prev <- current_rendered_roads()
    current_horizon <- input$time_horizon %||% "live"
    if (isTRUE(full_redraw) || !identical(current_road_horizon_loaded(), current_horizon) || nrow(prev) == 0) {
      proxy <- proxy %>% clearGroup("road_hazard_overlay")
      proxy <- proxy %>% addPolylines(
        data = roads,
        group = "road_hazard_overlay",
        layerId = ~road_id,
        color = ~road_color,
        opacity = ~road_opacity,
        weight = ~road_weight,
        smoothFactor = 0.1,
        popup = NULL,
        label = NULL,
        options = road_options
      )
      if (!("road_reference" %in% reference_layers())) {
        proxy <- proxy %>% hideGroup("road_hazard_overlay")
      }
      current_rendered_roads(sf::st_drop_geometry(roads[, c("road_id", "render_signature")]))
      current_road_horizon_loaded(current_horizon)
      return(invisible(TRUE))
    }

    curr <- sf::st_drop_geometry(roads[, c("road_id", "render_signature")])
    merged <- merge(curr, prev, by = "road_id", all = TRUE, suffixes = c("_new", "_old"))
    remove_ids <- merged$road_id[is.na(merged$render_signature_new)]
    changed_ids <- merged$road_id[
      is.na(merged$render_signature_old) |
        is.na(merged$render_signature_new) |
        merged$render_signature_new != merged$render_signature_old
    ]

    if (length(remove_ids) > 0) {
      proxy <- proxy %>% removeShape(layerId = remove_ids)
    }
    changed_roads <- roads[roads$road_id %in% changed_ids, , drop = FALSE]
    if (nrow(changed_roads) > 0) {
      proxy <- proxy %>% removeShape(layerId = changed_roads$road_id)
      proxy <- proxy %>% addPolylines(
        data = changed_roads,
        group = "road_hazard_overlay",
        layerId = ~road_id,
        color = ~road_color,
        opacity = ~road_opacity,
        weight = ~road_weight,
        smoothFactor = 0.1,
        popup = NULL,
        label = NULL,
        options = road_options
      )
    }
    if (!("road_reference" %in% reference_layers())) {
      proxy <- proxy %>% hideGroup("road_hazard_overlay")
    }
    current_rendered_roads(curr)
    current_road_horizon_loaded(current_horizon)
    invisible(TRUE)
  }

  observeEvent(current_map_payload(), {
    payload <- tryCatch(isolate(current_map_payload()), error = function(e) {
      showNotification(paste("Live map update failed:", conditionMessage(e)), type = "error", duration = 8)
      return(NULL)
    })
    if (is.null(payload) || is.null(payload$polys) || nrow(payload$polys) == 0) return()
    schedule_banded_map_render(payload)
  }, ignoreInit = FALSE)

  observe({
    payload <- pending_band_payload()
    bands <- pending_band_ids()
    idx <- suppressWarnings(as.integer(pending_band_index() %||% 0L))
    if (is.null(payload) || length(bands) == 0) return()
    if (idx >= length(bands)) return()
    invalidateLater(LATITUDE_BAND_RENDER_DELAY_MS, session)

    next_idx <- idx + 1L
    band_id <- bands[[next_idx]]
    band_polys <- payload$polys[suppressWarnings(as.integer(payload$polys$lat_band)) == band_id, , drop = FALSE]
    proxy <- leafletProxy("map")
    if (next_idx == 1L) {
      proxy <- proxy %>% clearGroup("risk_polygons") %>% clearPopups()
    }
    if (nrow(band_polys) > 0) {
      proxy <- add_risk_polygons_to_proxy(proxy, band_polys)
    }
    pending_band_index(next_idx)
    total_bands <- length(bands)
    push_progress(
      next_idx / total_bands,
      sprintf("Rendering Wisconsin band %d of %d from north to south.", next_idx, total_bands)
    )

    if (next_idx >= total_bands) {
      current_rendered(sf::st_drop_geometry(payload$polys[, c("zipcode", "render_signature")]))
      current_horizon_loaded(payload$horizon %||% (input$time_horizon %||% "live"))
      current_primary_loaded(payload$primary_map %||% DEFAULT_PRIMARY_MAP)
      roads <- payload$roads
      update_road_layer(roads, primary_map_key = payload$primary_map %||% DEFAULT_PRIMARY_MAP, full_redraw = TRUE)
      if (isTRUE(route_summary_open()) && length(current_route_result()$routes %||% list()) > 0) {
        render_route_result_on_map(current_route_result(), fit_view = FALSE, selected_rank = suppressWarnings(as.numeric(input$route_choice %||% NA)))
      }
      reset_progress()
      pending_band_payload(NULL)
      pending_band_ids(integer(0))
      pending_band_index(0L)
    }
  })

  observe({
    if (nrow(current_rendered()) == 0) return()
    q <- prefetch_queue()
    if (length(q) == 0) return()
    invalidateLater(2500, session)
    next_h <- q[1]
    if (identical(next_h, "zip_places")) {
      try(warm_zip_place_lookup(), silent = TRUE)
      prefetch_queue(q[-1])
      return()
    }
    try(prefetch_horizon(next_h), silent = TRUE)
    prefetch_queue(q[-1])
  })

  observeEvent(input$search_go, {
    result <- resolve_search_query(input$search_query %||% "")
    proxy <- leafletProxy("map") %>% clearGroup("search_highlight")

    if (is.null(result)) {
      showNotification("No ZIP, county, or city match found in Wisconsin.", type = "warning")
      return()
    }

    bb <- sf::st_bbox(result$geometry)
    proxy <- proxy %>% fitBounds(bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]])

    polys <- tryCatch(current_polygons(), error = function(e) wi_zctas)
    highlight_polys <- polys[polys$zipcode %in% unique(result$zipcodes), ]
    if (nrow(highlight_polys) > 0) {
      proxy %>% addPolylines(
        data = highlight_polys,
        group = "search_highlight",
        color = "#111111",
        weight = 3,
        opacity = 1,
        fill = FALSE,
        options = pathOptions(pane = "route_pane")
      )
    }
  }, ignoreInit = TRUE)

  observeEvent(input$map_shape_click, {
    if (!isTRUE(LAZY_ZIP_POPUPS_ENABLED)) return()
    click <- input$map_shape_click
    payload <- zip_popup_payload_from_click(click, tryCatch(current_polygons_snapshot(), error = function(e) NULL))
    if (is.null(payload)) return()
    proxy <- leafletProxy("map") %>% clearPopups()
    if (is.finite(payload$lng) && is.finite(payload$lat)) {
      proxy %>% addPopups(lng = payload$lng, lat = payload$lat, popup = payload$html)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$hover_notice_id, {
    current_hover_notice(input$hover_notice_id %||% "")
  }, ignoreInit = FALSE)

  observeEvent(input$dismiss_notice_id, {
    alert_id <- trimws(as.character(input$dismiss_notice_id %||% ""))
    if (!nzchar(alert_id)) return()
    dismissed_notice_ids(unique(c(dismissed_notice_ids(), alert_id)))
    if (identical(current_hover_notice() %||% "", alert_id)) current_hover_notice("")
  }, ignoreInit = TRUE)

  observeEvent(input$time_horizon, {
    dismissed_notice_ids(character(0))
    current_hover_notice("")
  }, ignoreInit = TRUE)

  observe({
    hovered <- current_hover_notice() %||% ""
    proxy <- leafletProxy("map") %>% clearGroup("notice_highlight")
    if (!nzchar(hovered)) return()

    alert_payload <- current_horizon_alert_payload()
    zips <- unique(alert_payload$notice_zip_map[[hovered]] %||% character(0))
    if (length(zips) == 0) return()

    polys <- tryCatch(current_polygons(), error = function(e) wi_zctas)
    highlight_polys <- polys[polys$zipcode %in% zips, ]
    if (nrow(highlight_polys) == 0) return()

    proxy %>% addPolylines(
      data = highlight_polys,
      group = "notice_highlight",
      color = "#000000",
      weight = 4,
      opacity = 1,
      fill = FALSE,
      options = pathOptions(pane = "route_pane")
    )
  })

  observe({
    invalidateLater(300000, session)
    try(purge_inactive_map_caches(input$time_horizon %||% "live", primary_map()), silent = TRUE)
    purge_expired_live_cache()
  })
})
