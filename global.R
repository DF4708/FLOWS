# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

options(stringsAsFactors = FALSE)

library(sf)
library(dplyr)
library(httr2)
library(jsonlite)
library(htmltools)

# Source modular function files in R/ into whatever environment global.R is
# being sourced into (e.g. .GlobalEnv at runtime, or a sandbox env in the smoke
# test). source(local = TRUE) evaluates in the calling environment, which here
# is global.R's own evaluation environment.
for (.r_file in sort(list.files(file.path(getwd(), "R"), pattern = "[.]R$", recursive = TRUE, full.names = TRUE))) {
  source(.r_file, local = TRUE)
}
if (exists(".r_file", inherits = FALSE)) rm(.r_file)

LAZY_ZIP_POPUPS_ENABLED <- TRUE

TARGET_STATE <- "WI"
TARGET_STATE_FIPS <- "55"
BORDER_STATE_FIPS <- c("55", "27", "19", "17", "26")
NOTICE_LIMIT <- 5L
ALERT_TTL_SECONDS <- 90L
FORECAST_TTL_SECONDS <- 900L
FAST_START_FEATURES <- c("alerts", "temperature", "wind", "precipitation")
ENVIRONMENTAL_MAP_FEATURES <- c(
  "alerts", "temperature", "wind", "precipitation",
  "qpf_flood", "winter", "convective", "fire", "heat", "cold", "air", "radiation", "seismic"
)
# Keep the synchronized driving overlay focused on the families that materially
# change near-term road safety by default. Less common families can still be
# loaded explicitly from the map filter without blocking the initial map.
TRANSPORT_SUPPORT_FEATURES <- c("alerts", "temperature", "wind", "precipitation", "qpf_flood", "winter", "convective", "fire", "air")
PRIMARY_MAP_CHOICES <- c(
  "Normalized environmental risk" = "environmental",
  "Wind risk" = "wind",
  "Flood risk" = "qpf_flood",
  "Winter risk" = "winter",
  "Fire risk" = "fire",
  "Storm risk" = "convective",
  "Heat risk" = "heat",
  "Cold risk" = "cold",
  "Air / smoke risk" = "air",
  "Radiation / UV risk" = "radiation",
  "Seismic risk" = "seismic"
)
DEFAULT_PRIMARY_MAP <- "environmental"
REFERENCE_LAYER_CHOICES <- c(
  "County outline overlay" = "county_outline",
  "ZIP overlay" = "zip_outline",
  "Live road-risk overlay" = "road_reference"
)
DEFAULT_REFERENCE_LAYERS <- c("county_outline", "zip_outline", "road_reference")
FORECAST_REGION_COUNT <- 18L
ROUTE_NODE_SNAP_METERS <- 25
ALERT_LINK_SEP <- "<<ALERTSEP>>"
NOAA_USER_AGENT_DEFAULT <- "Satellite-Flooding/1.0 (contact: d.foster@marquette.edu)"
NOAA_USER_AGENT <- trimws(Sys.getenv("NOAA_USER_AGENT", NOAA_USER_AGENT_DEFAULT))
if (!nzchar(NOAA_USER_AGENT)) NOAA_USER_AGENT <- NOAA_USER_AGENT_DEFAULT
WI511_API_KEY <- trimws(Sys.getenv("WI511_API_KEY", ""))
WI_MAGNETIC_DECLINATION_DEG <- -2.5
RISK_GREEN_MIN <- 0.3980
RISK_YELLOW_MIN <- 0.6990
RISK_RED_MIN <- 0.8751

CENSUS_ZCTA_URL <- "https://www2.census.gov/geo/tiger/GENZ2020/shp/cb_2020_us_zcta520_500k.zip"
CENSUS_COUNTY_URL <- "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_us_county_20m.zip"
CENSUS_STATE_URL <- "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_us_state_20m.zip"
CENSUS_PLACE_URL <- "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_55_place_500k.zip"
CENSUS_PRISECROADS_URL <- "https://www2.census.gov/geo/tiger/TIGER2025/PRISECROADS/tl_2025_55_prisecroads.zip"
EPA_UV_DAILY_URL <- "https://data.epa.gov/dmapservice/getEnvirofactsUVDAILY/ZIP/%s/JSON"
USGS_QUAKE_DAYS <- 7L
USGS_QUAKE_MIN_MAG <- 1.5
NWS_ALERTS_URL <- sprintf("https://api.weather.gov/alerts/active?area=%s", TARGET_STATE)
NWS_PUBLIC_ZONE_URLS <- c(
  "https://www.weather.gov/source/gis/Shapefiles/WSOM/z_16ap26.zip",
  "https://www.weather.gov/source/gis/Shapefiles/WSOM/z_18mr25.zip"
)
WPC_QPF_URLS <- list(
  live = "https://ftp.wpc.ncep.noaa.gov/shapefiles/qpf/day1/QPF24hr_Day1_latest.tar",
  `24h` = "https://ftp.wpc.ncep.noaa.gov/shapefiles/qpf/day1/QPF24hr_Day1_latest.tar",
  `48h` = "https://ftp.wpc.ncep.noaa.gov/shapefiles/qpf/day2/QPF24hr_Day2_latest.tar",
  `72h` = "https://ftp.wpc.ncep.noaa.gov/shapefiles/qpf/day3/QPF24hr_Day3_latest.tar"
)
WPC_WINTER_URLS <- list(
  live = c(
    snow4 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PSNOW_GT_04_latest.tar",
    snow8 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PSNOW_GT_08_latest.tar",
    snow12 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PSNOW_GT_12_latest.tar",
    ice25 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PICEZ_GT_25_latest.tar"
  ),
  `24h` = c(
    snow4 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PSNOW_GT_04_latest.tar",
    snow8 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PSNOW_GT_08_latest.tar",
    snow12 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PSNOW_GT_12_latest.tar",
    ice25 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day1/DAY1_PICEZ_GT_25_latest.tar"
  ),
  `48h` = c(
    snow4 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day2/DAY2_PSNOW_GT_04_latest.tar",
    snow8 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day2/DAY2_PSNOW_GT_08_latest.tar",
    snow12 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day2/DAY2_PSNOW_GT_12_latest.tar",
    ice25 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day2/DAY2_PICEZ_GT_25_latest.tar"
  ),
  `72h` = c(
    snow4 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day3/DAY3_PSNOW_GT_04_latest.tar",
    snow8 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day3/DAY3_PSNOW_GT_08_latest.tar",
    snow12 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day3/DAY3_PSNOW_GT_12_latest.tar",
    ice25 = "https://ftp.wpc.ncep.noaa.gov/shapefiles/ww/day3/DAY3_PICEZ_GT_25_latest.tar"
  )
)
WPC_FLOOD_OUTLOOK_URL <- "https://ftp.wpc.ncep.noaa.gov/shapefiles/fop/FLOODOUTLOOK_latest.tar"
OWP_FHO_BASE_URL <- "https://mapservices.weather.noaa.gov/experimental/rest/services/owp_fho/MapServer"
HEATRISK_KML_URLS <- list(
  live = "https://www.wpc.ncep.noaa.gov/heatrisk/data/HeatRisk_Day1_Fcst.kml",
  `24h` = "https://www.wpc.ncep.noaa.gov/heatrisk/data/HeatRisk_Day1_Fcst.kml",
  `48h` = "https://www.wpc.ncep.noaa.gov/heatrisk/data/HeatRisk_Day2_Fcst.kml",
  `72h` = "https://www.wpc.ncep.noaa.gov/heatrisk/data/HeatRisk_Day3_Fcst.kml"
)
SPC_FIRE_BASE_URL <- "https://mapservices.weather.noaa.gov/vector/rest/services/fire_weather/SPC_firewx/MapServer"
SPC_CONVECTIVE_BASE_URL <- "https://mapservices.weather.noaa.gov/vector/rest/services/outlooks/SPC_wx_outlks/MapServer"
AIRNOW_FILES_BASE_URL <- "https://files.airnowtech.org/airnow"
AIRNOW_REPORTINGAREA_URL <- paste0(AIRNOW_FILES_BASE_URL, "/today/reportingarea.dat")
AIRNOW_CITYZIPCODES_URL <- paste0(AIRNOW_FILES_BASE_URL, "/today/cityzipcodes.csv")
AIRNOW_OBS_LOOKBACK_HOURS <- 4L
NWPS_GAUGES_URL <- "https://api.water.noaa.gov/nwps/v1/gauges"
FFG_SERVICE_URL <- "https://mapservices.weather.noaa.gov/raster/rest/services/precip/rfc_gridded_ffg/MapServer"
FFG_LAYER_IDS <- c(`1h` = 3L, `3h` = 7L, `6h` = 11L)
GLM_GOES_BUCKETS <- trimws(unlist(strsplit(Sys.getenv("GLM_GOES_BUCKETS", "noaa-goes19,noaa-goes18,noaa-goes16,noaa-goes17"), ","), use.names = FALSE))
GLM_GOES_BUCKETS <- GLM_GOES_BUCKETS[nzchar(GLM_GOES_BUCKETS)]
GLM_PRODUCT_PREFIX <- trimws(Sys.getenv("GLM_PRODUCT_PREFIX", "GLM-L2-LCFA"))
GLM_LOOKBACK_MINUTES <- suppressWarnings(as.integer(Sys.getenv("GLM_LOOKBACK_MINUTES", "20")))
if (!is.finite(GLM_LOOKBACK_MINUTES) || GLM_LOOKBACK_MINUTES < 5L) GLM_LOOKBACK_MINUTES <- 20L
GLM_MAX_FILES_PER_PASS <- suppressWarnings(as.integer(Sys.getenv("GLM_MAX_FILES_PER_PASS", "18")))
if (!is.finite(GLM_MAX_FILES_PER_PASS) || GLM_MAX_FILES_PER_PASS < 1L) GLM_MAX_FILES_PER_PASS <- 18L
NRC_EVENT_RSS_URL <- "https://www.nrc.gov/public-involve/rss?feed=event"
NRC_EVENT_LOOKBACK_DAYS <- 14L
RADNET_WI_MONITOR_SPECS <- list(
  list(place_name = "La Crosse", slug = "LA_CROSSE"),
  list(place_name = "Madison", slug = "MADISON"),
  list(place_name = "Milwaukee", slug = "MILWAUKEE"),
  list(place_name = "Shawano", slug = "SHAWANO")
)
WI511_WINTER_ROADS_URL <- "https://511wi.gov/api/v3/get/winterroads"
WI511_TRAVEL_TIMES_URL <- "https://511wi.gov/api/v2/get/traveltimes"
WI511_EVENTS_URL <- "https://511wi.gov/api/v2/get/event"
WI511_ALERTS_URL <- "https://511wi.gov/api/v2/get/alerts"
WI511_MESSAGE_SIGNS_URL <- "https://511wi.gov/api/v2/get/messagesigns"
REFERENCE_DATA_DIR <- file.path("data", "reference")
REFERENCE_GPKG_PATH <- file.path(REFERENCE_DATA_DIR, "wisconsin_reference.gpkg")
REFERENCE_MANIFEST_PATH <- file.path(REFERENCE_DATA_DIR, "wisconsin_reference_manifest.json")
RUNTIME_CACHE_DIR <- file.path("data", "runtime_cache")
STARTUP_MAP_SNAPSHOT_PATH <- file.path(RUNTIME_CACHE_DIR, "startup_live_environmental.rds")
ALERT_SNAPSHOT_PATH <- file.path(RUNTIME_CACHE_DIR, "alerts_live_snapshot.rds")
ZIP_NEIGHBOR_SNAPSHOT_PATH <- file.path(RUNTIME_CACHE_DIR, "zip_neighbors_static.rds")
STARTUP_WARMER_LOCK_PATH <- file.path(RUNTIME_CACHE_DIR, "startup_live_environmental.lock.rds")
STARTUP_WARMER_LOG_PATH <- file.path(RUNTIME_CACHE_DIR, "startup_live_environmental.log")
USE_LOCAL_REFERENCE_ONLY <- tolower(trimws(Sys.getenv("USE_LOCAL_REFERENCE_ONLY", "false"))) %in% c("1", "true", "yes")
RISK_PROFILE_CSV <- file.path("data", "wi_latitude_band_profiles.csv")
DEFAULT_LAT_BAND_ANNUAL_AVG_TEMPS_F <- stats::setNames(c(48, 47, 46, 45, 44, 43, 42, 41, 40, 39), as.character(1:10))
DEFAULT_HTTP_TIMEOUT_SECONDS <- 20L
DEFAULT_HTTP_MAX_TRIES <- 1L
DEFAULT_DOWNLOAD_TIMEOUT_SECONDS <- 45L
STARTUP_SNAPSHOT_MAX_AGE_SECONDS <- 20L * 60L
STARTUP_WARMER_TRIGGER_AGE_SECONDS <- 5L * 60L
STARTUP_WARMER_MAX_AGE_SECONDS <- 20L * 60L

live_cache <- new.env(parent = emptyenv())
namespace_limits <- list(points = 128L, forecast = 128L, alerts = 8L, reference = 8L, derived = 32L, horizon = 32L)
MAX_CACHE_KEY_BYTES <- 2048L
MAX_CACHE_KEY_PREFIX_CHARS <- 512L

ref_geo <- load_reference_geographies()
wi_zctas <- ref_geo$zctas
wi_counties <- ref_geo$counties
wi_bounds <- as.list(sf::st_bbox(wi_zctas))
names(wi_bounds) <- c("west", "south", "east", "north")
wi_state_geom <- suppressWarnings(sf::st_union(wi_counties))
wi_state_outline <- suppressWarnings(sf::st_boundary(wi_state_geom))

risk_band_profiles <- utils::read.csv(RISK_PROFILE_CSV, stringsAsFactors = FALSE)
zip_centroids <- point_on_surface_lonlat(wi_zctas)
wi_zip_points <- zip_centroids
cent_xy <- sf::st_coordinates(zip_centroids)
wi_zctas$center_lon <- cent_xy[, 1]
wi_zctas$center_lat <- cent_xy[, 2]
wi_zctas$lat_band <- assign_lat_band(wi_zctas$center_lat, wi_bounds$south, wi_bounds$north, 10L)

# Pre-projected reference geometries (EPSG:5070, US Albers Equal Area meters).
# Many downstream modules (glm, nwps, uv_seismic, wi511, zone_alerts) call
# sf::st_transform on wi_zip_points / wi_zctas to project distance / overlap
# math into meters. The transform is deterministic for these static geometries,
# so caching the projected versions once at module load avoids ~7 redundant
# st_transform passes per build (~100-300 ms cold-start savings).
wi_zip_points_proj <- suppressWarnings(sf::st_transform(wi_zip_points, 5070))
wi_zctas_proj <- suppressWarnings(sf::st_transform(wi_zctas, 5070))

band_reps <- wi_zctas |>
  sf::st_drop_geometry() |>
  dplyr::group_by(lat_band) |>
  dplyr::summarise(rep_lon = mean(center_lon, na.rm = TRUE), rep_lat = mean(center_lat, na.rm = TRUE), rep_zip = dplyr::first(zipcode), .groups = "drop")

forecast_region_context <- build_forecast_region_context(wi_zctas)
wi_zctas$forecast_region <- forecast_region_context$assignments
forecast_region_reps <- forecast_region_context$reps

state_fast_point <- point_on_surface_lonlat(sf::st_sf(id = 1L, geometry = sf::st_sfc(wi_state_geom, crs = 4326)))
state_fast_xy <- sf::st_coordinates(state_fast_point)
state_fast_lat <- state_fast_xy[1, 2]
state_fast_lon <- state_fast_xy[1, 1]

zip_static <- wi_zctas
zip_static$place_name <- NA_character_
zip_static$horizon_label <- "Live"

# Route selection contract (keep this aligned with the UI copy and route tests):
# - Fastest: choose the lowest-time drivable route, prefer highways early, accept more risk
#   when that still yields the quickest arrival, and serve as the time baseline.
# - Safest: choose the lowest-risk drivable route within the same 1.5x time ceiling relative
#   to Fastest, prefer transparent > green > yellow > red, avoid red entirely when possible,
#   and use low-risk ZIP detours rather than metro hub routing.
# - Metro/Rail: choose a hub-based city-to-city highway corridor within the same 1.5x time
#   ceiling, pass through meaningful town/city hubs when those corridors exist, and sit
#   between Fastest and Safest on risk tolerance.
# - Ordering target: Fastest is time-first/highest-risk-tolerance; Safest is lowest-risk;
#   Metro/Rail is the middle-risk hub-corridor option and should not collapse into Safest.

