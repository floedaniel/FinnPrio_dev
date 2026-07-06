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
SPECIES_DIR <-  "C:/Users/dafl/OneDrive - Folkehelseinstituttet/Prosjektdata - Dokumenter/VKM Data/26.08.2024_lopende_oppdrag_plantehelse/Species"
               
DB_PATH <- "C:/Dev/FinnPrio/FinnPRIO_development/databases/daniel_database_2026/daniel_v009_2026-04-20T11-16-00.db"
THRESHOLD <- 0.1                  # fallback only; JSON optimal_threshold wins
AREA_FLOOR_PCT <- 0.1             # verdict "NO" if pct_area_suitable < this
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

# Compute per-region suitability stats from a continuous suitability raster.
# Returns list(norway=..., sweden=..., tiff_path=...) or NULL on error.
analyze_tiff <- function(tiff_path, threshold) {
  tryCatch({
    r <- rast(tiff_path)

    stats_for <- function(region_ext) {
      r_reg <- crop(r, region_ext)
      vals  <- values(r_reg, na.rm = TRUE)
      if (length(vals) == 0) {
        return(list(threshold = threshold, max_suit = 0, pct_area = 0,
                    n_cells = 0, suitable = FALSE))
      }
      pct <- 100 * sum(vals >= threshold) / length(vals)
      list(
        threshold = threshold,
        max_suit  = max(vals),
        pct_area  = pct,
        n_cells   = length(vals),
        suitable  = pct >= AREA_FLOOR_PCT
      )
    }

    list(
      norway    = stats_for(NORWAY),
      sweden    = stats_for(SWEDEN),
      tiff_path = tiff_path
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

# Convert a predictor variable name from model_summary.json into a display label.
# Handles BIO* (lookup via BIOCLIM_LABELS after stripping suffix), SBIO*,
# and generic names (underscores -> spaces).
pretty_var_name <- function(var) {
  bio_key <- sub("^(BIO\\d+)_.*", "\\1", var)
  if (bio_key %in% names(BIOCLIM_LABELS)) {
    return(paste0(BIOCLIM_LABELS[[bio_key]], " (", bio_key, ")"))
  }
  gsub("_", " ", var)
}

build_justification <- function(summary_json, tiff_result, sdm_folder, species_key) {
  sp_name <- if (!is.null(summary_json)) summary_json$species %||% species_key else species_key

  # -------- Block 1: verdict line --------
  if (!is.null(tiff_result)) {
    nor <- tiff_result$norway
    if (nor$suitable) {
      verdict <- sprintf(
        "Establishment in Norway: YES (%.1f%% of area suitable).",
        nor$pct_area
      )
    } else {
      verdict <- sprintf(
        "Establishment in Norway: NO (%.1f%% of area suitable, below %.1f%% floor).",
        nor$pct_area, AREA_FLOOR_PCT
      )
    }
  } else {
    verdict <- "Establishment in Norway: UNKNOWN (raster analysis unavailable)."
  }

  # -------- Block 2: narrative paragraph --------
  sentences <- c()

  # Sentence 1: model + species + data
  if (!is.null(summary_json)) {
    sentences <- c(sentences, sprintf(
      "MaxEnt species distribution model for %s (n=%d presences, %d background points).",
      sp_name,
      summary_json$n_presence %||% 0,
      summary_json$n_background %||% 0
    ))
  } else {
    sentences <- c(sentences, sprintf("MaxEnt species distribution model for %s.", sp_name))
  }

  # Sentences 2-3: Norway + Sweden numbers
  if (!is.null(tiff_result)) {
    nor <- tiff_result$norway
    swe <- tiff_result$sweden

    sentences <- c(sentences, sprintf(
      "Approximately %.1f%% of Norwegian land area exceeds the maxTSS-optimized suitability threshold (%.3f) under the clamped current-climate projection (max cell suitability = %.3f).",
      nor$pct_area, nor$threshold, nor$max_suit
    ))

    delta <- swe$pct_area - nor$pct_area
    comparator <- if (delta > 2) "broader"
                  else if (delta < -2) "narrower"
                  else "comparable"
    trailing <- if (delta > 2) "consistent with a northward establishment gradient"
                else if (delta < -2) "suggesting a limited Fennoscandian range relative to Norway"
                else "indicating similar suitability across southern Fennoscandia"

    sentences <- c(sentences, sprintf(
      "Sweden shows %s suitability (%.1f%%), %s.",
      comparator, swe$pct_area, trailing
    ))
  } else {
    sentences <- c(sentences, "Raster analysis unavailable (current_clamped TIFF not found).")
  }

  # Sentence 4: model performance
  if (!is.null(summary_json)) {
    perf <- c()
    if (!is.null(summary_json$auc_test))    perf <- c(perf, sprintf("AUC(test)=%.3f", summary_json$auc_test))
    if (!is.null(summary_json$tss_test))    perf <- c(perf, sprintf("TSS=%.3f",       summary_json$tss_test))
    if (!is.null(summary_json$boyce_index)) perf <- c(perf, sprintf("Boyce=%.3f",     summary_json$boyce_index))
    if (length(perf) > 0) {
      sentences <- c(sentences, sprintf("Model performance: %s.", paste(perf, collapse = ", ")))
    }
  }

  # Sentence 5: top 3 predictors
  if (!is.null(summary_json) && !is.null(summary_json$variables)) {
    vars <- summary_json$variables
    imp  <- summary_json$variable_importance
    n_top <- min(3, length(vars))
    top_parts <- character(n_top)
    for (i in seq_len(n_top)) {
      label <- pretty_var_name(vars[i])
      top_parts[i] <- if (!is.null(imp) && length(imp) >= i) {
        sprintf("%s (%.1f%%)", label, imp[i])
      } else {
        label
      }
    }
    sentences <- c(sentences, sprintf("Key predictors: %s.", paste(top_parts, collapse = ", ")))
  }

  # Sentence 6: SSP585 future
  if (!is.null(summary_json) && !is.null(summary_json$ssp585_mean_change)) {
    sentences <- c(sentences, sprintf(
      "Future projections (SSP585 2021-2040): mean suitability change = %+.4f (%.1f%% gaining, %.1f%% losing).",
      summary_json$ssp585_mean_change,
      summary_json$ssp585_gain_pct %||% NA_real_,
      summary_json$ssp585_loss_pct %||% NA_real_
    ))
  }

  # Sentence 7: MESS caveat (only if extrapolation high)
  if (!is.null(summary_json) &&
      !is.null(summary_json$mess_pct_extrapolation) &&
      summary_json$mess_pct_extrapolation > 50) {
    sentences <- c(sentences, sprintf(
      "MESS analysis flags %.1f%% of the projection area as climatically novel relative to training data - interpret Norwegian projections with caution.",
      summary_json$mess_pct_extrapolation
    ))
  }

  # Fallback if JSON missing entirely
  if (is.null(summary_json)) {
    sentences <- c(sentences, "Model summary JSON not found; only raster-based suitability was computed.")
  }

  narrative <- paste(sentences, collapse = " ")

  # -------- Block 3: PNG maps --------
  pngs <- find_png_maps(sdm_folder, species_key)
  maps_block <- if (length(pngs) > 0) {
    paste0("Maps: ", paste(basename(pngs), collapse = "; "), ".")
  } else {
    NULL
  }

  # -------- Closing tag --------
  closing <- sprintf("[Source: VKM SDMtune/MaxEnt, folder: %s/]", SDM_FOLDER)

  blocks <- c(verdict, narrative, maps_block, closing)
  paste(blocks[!is.null(blocks) & nzchar(blocks)], collapse = "\n\n")
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

    # Strip new-format block (idempotent re-run)
    stripped <- sub(
      "\\n*Establishment in Norway:.*\\[Source: VKM SDMtune/MaxEnt[^\\]]*\\]",
      "", existing, perl = TRUE
    )
    # Strip legacy markers from earlier script versions
    stripped <- sub("\\n\\n(MaxEnt/SDMtune|Maxent model)\\n.*$", "", stripped, perl = TRUE)
    stripped <- sub("\\s+$", "", stripped)

    new_just <- if (nzchar(stripped)) paste0(stripped, "\n\n", justification) else justification

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
      "No %s model folder exists for this species (%s). [Source: VKM SDMtune/MaxEnt]",
      SDM_FOLDER, pest$eppoCode
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
    nor <- tiff_result$norway
    swe <- tiff_result$sweden
    cat(sprintf("  Norway: %.1f%% suitable (max=%.3f, thr=%.3f) -> %s\n",
                nor$pct_area, nor$max_suit, nor$threshold,
                if (nor$suitable) "YES" else "NO"))
    cat(sprintf("  Sweden: %.1f%% suitable (max=%.3f) -> %s\n\n",
                swe$pct_area, swe$max_suit,
                if (swe$suitable) "YES" else "NO"))
  } else {
    cat("  No TIFF found for raster analysis\n\n")
  }

  update_db(output_db, pest$idAssessment, justification)
}

cat("=== DONE ===\n")
cat("Output:", output_db, "\n")
