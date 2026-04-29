# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1) args[[1]] else "."
project_dir <- normalizePath(project_dir, mustWork = FALSE)

fail <- function(message) {
  cat(sprintf("ERROR: %s
", message), file = stderr())
  quit(save = "no", status = 1)
}

required_packages <- c("sf", "dplyr", "httr2", "jsonlite", "htmltools", "shiny", "leaflet")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_packages) > 0) {
  fail(sprintf("Missing required R packages: %s", paste(missing_packages, collapse = ", ")))
}

setwd(project_dir)
local_only <- tolower(trimws(Sys.getenv("USE_LOCAL_REFERENCE_ONLY", "false"))) %in% c("1", "true", "yes")
gpkg_path <- file.path("data", "reference", "wisconsin_reference.gpkg")
manifest_path <- file.path("data", "reference", "wisconsin_reference_manifest.json")
if (isTRUE(local_only) && (!file.exists(gpkg_path) || !file.exists(manifest_path))) {
  fail("USE_LOCAL_REFERENCE_ONLY=true but the bundled Wisconsin reference assets are missing.")
}

env <- new.env(parent = globalenv())
source_result <- tryCatch(source("global.R", local = env), error = function(e) e)
if (inherits(source_result, "error")) fail(sprintf("global.R failed to source: %s", source_result$message))

required_objects <- c("wi_zctas", "wi_counties", "wi_state_geom")
for (obj in required_objects) {
  if (!exists(obj, envir = env, inherits = FALSE)) fail(sprintf("Required object missing after sourcing global.R: %s", obj))
}
if (!inherits(get("wi_zctas", envir = env), "sf") || nrow(get("wi_zctas", envir = env)) < 1) {
  fail("wi_zctas did not load as a non-empty sf object.")
}
if (!inherits(get("wi_counties", envir = env), "sf") || nrow(get("wi_counties", envir = env)) < 1) {
  fail("wi_counties did not load as a non-empty sf object.")
}

ui_result <- tryCatch(source("ui.R", local = env), error = function(e) e)
if (inherits(ui_result, "error")) fail(sprintf("ui.R failed to source: %s", ui_result$message))
if (is.null(ui_result$value)) fail("ui.R did not return a UI value.")

server_result <- tryCatch(source("server.R", local = env), error = function(e) e)
if (inherits(server_result, "error")) fail(sprintf("server.R failed to source: %s", server_result$message))
server_obj <- if (exists("server", envir = env, inherits = FALSE)) get("server", envir = env) else server_result$value
if (is.null(server_obj)) fail("server.R did not create a server function.")

cat("Runtime smoke test passed: global.R, ui.R, and server.R all sourced successfully.
")
