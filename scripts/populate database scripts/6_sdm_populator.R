# =============================================================================
# SDM Establishment Populator
# Populates EST1 justification with Maxent model results for Norway/Sweden
# Reads model_summary.json from SDMtune_updated_2 folders
# =============================================================================

library(terra)
library(DBI)
library(RSQLite)
library(jsonlite)

# CONFIG - UPDATE THESE PATHS
SPECIES_DIR <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/VKM Data/26.08.2024_lopende_oppdrag_plantehelse/Species"
DB_PATH <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/daniel_database_2026/test_sdm.db"
THRESHOLD <- 0.1
SDM_FOLDER <- "SDMtune_updated_2"

# Norway/Sweden bounds
NORWAY <- ext(4, 31, 58, 71.5)
SWEDEN <- ext(11, 24, 55, 69)

# =============================================================================
# FUNCTIONS
# =============================================================================

BIOCLIM_LABELS <- c(
  BIO1  = "Annual Mean Temperature",
  BIO2  = "Mean Diurnal Range",
  BIO3  = "Isothermality",
  BIO4  = "Temperature Seasonality",
  BIO5  = "Max Temperature of Warmest Month",
  BIO6  = "Min Temperature of Coldest Month",
  BIO7  = "Temperature Annual Range",
  BIO8  = "Mean Temperature of Wettest Quarter",
  BIO9  = "Mean Temperature of Driest Quarter",
  BIO10 = "Mean Temperature of Warmest Quarter",
  BIO11 = "Mean Temperature of Coldest Quarter",
  BIO12 = "Annual Precipitation",
  BIO13 = "Precipitation of Wettest Month",
  BIO14 = "Precipitation of Driest Month",
  BIO15 = "Precipitation Seasonality",
  BIO16 = "Precipitation of Wettest Quarter",
  BIO17 = "Precipitation of Driest Quarter",
  BIO18 = "Precipitation of Warmest Quarter",
  BIO19 = "Precipitation of Coldest Quarter"
)

analyze_tiff <- function(tiff_path, threshold = THRESHOLD) {
  tryCatch({
    r <- rast(tiff_path)

    r_nor <- crop(r, NORWAY)
    vals_nor <- values(r_nor, na.rm = TRUE)
    max_nor <- if(length(vals_nor) > 0) max(vals_nor) else 0

    r_swe <- crop(r, SWEDEN)
    vals_swe <- values(r_swe, na.rm = TRUE)
    max_swe <- if(length(vals_swe) > 0) max(vals_swe) else 0

    list(
      norway_suitable = max_nor >= threshold,
      sweden_suitable = max_swe >= threshold,
      max_norway = max_nor,
      max_sweden = max_swe,
      threshold_used = threshold
    )
  }, error = function(e) {
    cat("    ERROR analyzing TIFF:", e$message, "\n")
    NULL
  })
}

parse_model_summary <- function(sdm_folder) {
  json_path <- file.path(sdm_folder, "model_summary", "model_summary.json")
  if (!file.exists(json_path)) return(NULL)
  tryCatch(
    fromJSON(json_path),
    error = function(e) {
      cat("    ERROR reading model_summary.json:", e$message, "\n")
      NULL
    }
  )
}

find_png_maps <- function(sdm_folder, species_key) {
  patterns <- c(
    current_europe = paste0("current_europe_clamped_", species_key, ".png"),
    future_europe  = paste0("future_europe_clamped_", species_key, ".png"),
    binary_current = "th_current_binary_maxTSS_clamped.png",
    binary_future  = "th_future_binary_maxTSS_clamped.png"
  )
  found <- sapply(patterns, function(p) {
    f <- file.path(sdm_folder, p)
    if (file.exists(f)) f else NA_character_
  })
  found[!is.na(found)]
}

# Null-coalescing helper
`%||%` <- function(a, b) if (!is.null(a) && !is.na(a)) a else b

build_justification <- function(summary_json, tiff_result, sdm_folder, species_key) {
  parts <- c()
  sp_name <- if (!is.null(summary_json)) summary_json$species %||% species_key else species_key

  # 1. Intro
  parts <- c(parts, sprintf("Species distribution model for %s.", sp_name))

  # 2. Establishment potential — Norway is primary, Sweden supplementary
  if (!is.null(tiff_result)) {
    thr <- tiff_result$threshold_used
    nor_str <- sprintf("Norway (max=%.3f)", tiff_result$max_norway)
    swe_str <- sprintf("also suitable in Sweden (max=%.3f)", tiff_result$max_sweden)

    if (tiff_result$norway_suitable) {
      extra <- if (tiff_result$sweden_suitable) paste0("; ", swe_str) else ""
      parts <- c(parts, sprintf(
        "Suitable habitat EXISTS in %s%s (threshold=%.3f, maxTSS binary map).",
        nor_str, extra, thr
      ))
    } else {
      extra <- if (tiff_result$sweden_suitable) sprintf("; however suitable in Sweden (max=%.3f)", tiff_result$max_sweden) else ""
      parts <- c(parts, sprintf(
        "NO suitable habitat in Norway (max=%.3f)%s — below model threshold %.3f (maxTSS binary map).",
        tiff_result$max_norway, extra, thr
      ))
    }
  } else {
    parts <- c(parts, "Raster analysis not available (current_clamped TIFF not found).")
  }

  # 3. Future projections
  if (!is.null(summary_json$ssp585_mean_change)) {
    mean_chg  <- summary_json$ssp585_mean_change
    gain_pct  <- summary_json$ssp585_gain_pct
    loss_pct  <- summary_json$ssp585_loss_pct
    direction <- if (mean_chg > 0) "increase" else "decrease"
    parts <- c(parts, sprintf(
      "Future projections (SSP585 2021-2040): mean suitability change = %.4f (%s); %.1f%% gaining, %.1f%% losing.",
      mean_chg, direction, gain_pct %||% NA, loss_pct %||% NA
    ))
  }

  # 4. Predictors + performance + data
  if (!is.null(summary_json)) {
    vars <- summary_json$variables
    imp  <- summary_json$variable_importance
    var_str <- if (!is.null(vars)) {
      labels <- BIOCLIM_LABELS[toupper(vars)]
      named  <- ifelse(is.na(labels), vars, paste0(labels, " (", vars, ")"))
      if (!is.null(imp)) named <- paste0(named, " ", round(imp, 1), "%")
      paste(named, collapse = ", ")
    } else {
      "not reported"
    }

    perf_parts <- c()
    if (!is.null(summary_json$auc_test))    perf_parts <- c(perf_parts, sprintf("AUC(test)=%.3f",   summary_json$auc_test))
    if (!is.null(summary_json$tss_test))    perf_parts <- c(perf_parts, sprintf("TSS(test)=%.3f",   summary_json$tss_test))
    if (!is.null(summary_json$auc_cv))      perf_parts <- c(perf_parts, sprintf("AUC(CV)=%.3f",     summary_json$auc_cv))
    if (!is.null(summary_json$boyce_index)) perf_parts <- c(perf_parts, sprintf("Boyce=%.3f",       summary_json$boyce_index))

    perf_str <- if (length(perf_parts) > 0) paste(perf_parts, collapse = ", ") else ""
    data_str <- sprintf("using %d presences and %d background points",
                        summary_json$n_presence %||% 0, summary_json$n_background %||% 0)

    mess_str <- if (!is.null(summary_json$mess_pct_extrapolation))
      sprintf("; MESS extrapolation %.1f%%", summary_json$mess_pct_extrapolation) else ""

    parts <- c(parts, sprintf(
      "Key predictors: %s. Model performance: %s %s%s.",
      var_str, perf_str, data_str, mess_str
    ))
  }

  # --- PNG map references ---
  pngs <- find_png_maps(sdm_folder, species_key)
  if (length(pngs) > 0) {
    parts <- c(parts, paste0("Maps: ", paste(basename(pngs), collapse = "; "), "."))
  }

  parts <- c(parts, sprintf("[Model folder: %s]", sdm_folder))

  paste(parts, collapse = " ")
}

update_db <- function(db_path, id_assessment, justification) {
  con <- dbConnect(SQLite(), db_path)
  est1 <- dbGetQuery(con, "
    SELECT a.idAnswer, a.justification FROM answers a
    JOIN questions q ON a.idQuestion = q.idQuestion
    WHERE a.idAssessment = ? AND q.[group] = 'EST' AND q.number = '1'
  ", params = list(id_assessment))

  if (nrow(est1) > 0) {
    existing <- est1$justification[1]
    if (is.na(existing)) existing <- ""

    if (grepl("MaxEnt/SDMtune", existing) || grepl("Maxent model", existing)) {
      new_just <- sub("\n\n(MaxEnt/SDMtune|Maxent model)\n.*$", "", existing)
      new_just <- paste0(new_just, "\n\n", justification)
    } else {
      new_just <- paste0(existing, "\n\n", justification)
    }

    dbExecute(con, "UPDATE answers SET justification = ? WHERE idAnswer = ?",
              params = list(new_just, est1$idAnswer[1]))
  }
  dbDisconnect(con)
}

# =============================================================================
# MAIN
# =============================================================================

cat("\n=== SDM ESTABLISHMENT POPULATOR ===\n\n")

# Get pests from DB
con <- dbConnect(SQLite(), DB_PATH)
pests <- dbGetQuery(con, "
  SELECT DISTINCT p.idPest, p.scientificName, UPPER(p.eppoCode) as eppoCode, a.idAssessment
  FROM pests p JOIN assessments a ON p.idPest = a.idPest
  WHERE p.eppoCode IS NOT NULL
")
dbDisconnect(con)

cat("Found", nrow(pests), "pests in database\n")

# Build map: eppoCode -> SDMtune_updated_2 folder path
species_top_dirs <- list.dirs(SPECIES_DIR, recursive = FALSE)
sdm_folder_map <- list()
for (d in species_top_dirs) {
  key <- toupper(basename(d))
  sdm_dir <- file.path(d, SDM_FOLDER)
  if (dir.exists(sdm_dir)) {
    sdm_folder_map[[key]] <- sdm_dir
  }
}
cat("Found", length(sdm_folder_map), "species folders with", SDM_FOLDER, "\n\n")

# Copy DB
output_db <- gsub("\\.db$", "_sdm.db", DB_PATH)
file.copy(DB_PATH, output_db, overwrite = TRUE)
cat("Output DB:", output_db, "\n\n")

# Process each pest
for (i in 1:nrow(pests)) {
  pest <- pests[i, ]
  cat(sprintf("[%d/%d] %s - %s\n", i, nrow(pests), pest$eppoCode, pest$scientificName))

  # No SDMtune_updated_2 folder
  if (!pest$eppoCode %in% names(sdm_folder_map)) {
    cat("  No", SDM_FOLDER, "folder found\n\n")
    justification <- sprintf(
      "No SDMtune_updated_2 model folder exists for this species (%s). [Source: VKM SDMtune/MaxEnt]",
      pest$eppoCode
    )
    update_db(output_db, pest$idAssessment, justification)
    next
  }

  sdm_folder <- sdm_folder_map[[pest$eppoCode]]

  # No occurrence data flag
  no_data_file <- list.files(sdm_folder, pattern = "no_occurrence_data\\.txt$", full.names = TRUE)[1]
  if (!is.na(no_data_file)) {
    cat("  No occurrence data - model could not be built\n\n")
    justification <- sprintf(
      "No Maxent model built. Reason: Insufficient occurrence data available for species distribution modeling. [Model folder: %s] [Source: VKM SDMtune/MaxEnt]",
      sdm_folder
    )
    update_db(output_db, pest$idAssessment, justification)
    next
  }

  # Parse model summary JSON
  summary_json <- parse_model_summary(sdm_folder)

  # Find current_clamped TIFF in rasters/ subfolder
  tiff_file <- file.path(sdm_folder, "rasters", paste0("current_clamped_", pest$eppoCode, ".tif"))
  if (!file.exists(tiff_file)) {
    tiff_file <- list.files(file.path(sdm_folder, "rasters"), pattern = "current_clamped.*\\.tif$", full.names = TRUE)[1]
  }

  opt_threshold <- summary_json$optimal_threshold %||% THRESHOLD
  tiff_result <- if (!is.na(tiff_file) && file.exists(tiff_file)) analyze_tiff(tiff_file, opt_threshold) else NULL

  # Build justification
  justification <- build_justification(summary_json, tiff_result, sdm_folder, pest$eppoCode)

  # Report
  if (!is.null(tiff_result)) {
    if (tiff_result$norway_suitable || tiff_result$sweden_suitable) {
      cat("  SUITABLE HABITAT detected\n\n")
    } else {
      cat(sprintf("  No suitable habitat (Norway: %.3f  Sweden: %.3f)\n\n",
                  tiff_result$max_norway, tiff_result$max_sweden))
    }
  } else {
    cat("  No TIFF found for raster analysis\n\n")
  }

  update_db(output_db, pest$idAssessment, justification)
}

cat("=== DONE ===\n")
cat("Output:", output_db, "\n")
