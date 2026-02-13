# =============================================================================
# SDM Establishment Populator
# Populates EST1 justification with Maxent model results for Norway/Sweden
# =============================================================================

library(terra)
library(DBI)
library(RSQLite)

# CONFIG - UPDATE THESE PATHS
SPECIES_DIR <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/VKM Data/26.08.2024_lopende_oppdrag_plantehelse/Species"
DB_PATH <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/VKM Data/26.08.2024_lopende_oppdrag_plantehelse/FinnPrio databaser/Selamavit/selam_2026_ai_enhanced_09_02_2026.db"
THRESHOLD <- 0.1

# Norway/Sweden bounds
NORWAY <- ext(4, 31, 58, 71.5)
SWEDEN <- ext(11, 24, 55, 69)

# =============================================================================
# FUNCTIONS
# =============================================================================

analyze_tiff <- function(tiff_path) {
  tryCatch({
    r <- rast(tiff_path)

    r_nor <- crop(r, NORWAY)
    vals_nor <- values(r_nor, na.rm = TRUE)
    max_nor <- if(length(vals_nor) > 0) max(vals_nor) else 0

    r_swe <- crop(r, SWEDEN)
    vals_swe <- values(r_swe, na.rm = TRUE)
    max_swe <- if(length(vals_swe) > 0) max(vals_swe) else 0

    list(
      norway_suitable = max_nor >= THRESHOLD,
      sweden_suitable = max_swe >= THRESHOLD,
      max_norway = max_nor,
      max_sweden = max_swe
    )
  }, error = function(e) {
    cat("    ERROR:", e$message, "\n")
    NULL
  })
}

parse_html <- function(html_path) {
  tryCatch({
    content <- paste(readLines(html_path, warn = FALSE), collapse = " ")
    text <- gsub("<[^>]+>", " ", content)
    text <- gsub("[ ]+", " ", text)

    metrics <- list()
    m <- regmatches(text, regexpr("Model type: (\\w+)", text, perl = TRUE))
    if (length(m) > 0) metrics$model_type <- gsub("Model type: ", "", m)

    m <- regmatches(text, regexpr("Train locations: \\d+ presence: (\\d+)", text, perl = TRUE))
    if (length(m) > 0) {
      nums <- as.numeric(regmatches(m, gregexpr("\\d+", m))[[1]])
      metrics$n_presence <- nums[2]
    }
    metrics
  }, error = function(e) list())
}

build_justification <- function(metrics, tiff_result, folder_path) {
  parts <- c()

  # Model info
  txt <- if (!is.null(metrics$model_type)) {
    paste0("A ", metrics$model_type, " species distribution model was developed")
  } else {
    "A MaxEnt species distribution model was developed"
  }
  if (!is.null(metrics$n_presence)) {
    txt <- paste0(txt, " using ", metrics$n_presence, " occurrence records")
  }
  parts <- c(parts, paste0(txt, "."))

  # Establishment assessment
  if (!is.null(tiff_result)) {
    if (tiff_result$norway_suitable || tiff_result$sweden_suitable) {
      regions <- c()
      if (tiff_result$norway_suitable) regions <- c(regions, paste0("Norway (max=", round(tiff_result$max_norway, 2), ")"))
      if (tiff_result$sweden_suitable) regions <- c(regions, paste0("Sweden (max=", round(tiff_result$max_sweden, 2), ")"))
      parts <- c(parts, paste0("ESTABLISHMENT POTENTIAL: Suitable habitat EXISTS in ", paste(regions, collapse = " and "), "."))
    } else {
      parts <- c(parts, paste0(
        "ESTABLISHMENT POTENTIAL: NO suitable habitat in Norway (max=", round(tiff_result$max_norway, 3),
        ") or Sweden (max=", round(tiff_result$max_sweden, 3), "). Values below ", THRESHOLD, " threshold."
      ))
    }
  } else {
    parts <- c(parts, "No Maxent model map (map.tif) found in folder. ESTABLISHMENT POTENTIAL: Could not be analyzed.")
  }

  parts <- c(parts, paste0("[Model folder: ", folder_path, "]"))
  parts <- c(parts, "[Source: VKM SDMtune/MaxEnt]")
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

    if (grepl("Maxent model", existing)) {
      new_just <- sub("\n\nMaxent model\n.*$", "", existing)
      new_just <- paste0(new_just, "\n\nMaxent model\n", justification)
    } else {
      new_just <- paste0(existing, "\n\nMaxent model\n", justification)
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

# Get folders
folders <- list.dirs(SPECIES_DIR, recursive = FALSE)
folder_map <- setNames(folders, toupper(basename(folders)))
cat("Found", length(folders), "species folders\n\n")

# Copy DB
output_db <- gsub("\\.db$", "_sdm.db", DB_PATH)
file.copy(DB_PATH, output_db, overwrite = TRUE)
cat("Output DB:", output_db, "\n\n")

# Process each pest
for (i in 1:nrow(pests)) {
  pest <- pests[i, ]
  cat(sprintf("[%d/%d] %s - %s\n", i, nrow(pests), pest$eppoCode, pest$scientificName))

  # No folder
  if (!pest$eppoCode %in% names(folder_map)) {
    cat("  No folder found\n\n")
    justification <- paste0("No Maxent model folder exists for this species (", pest$eppoCode, "). [Source: VKM SDMtune/MaxEnt]")
    update_db(output_db, pest$idAssessment, justification)
    next
  }

  folder <- folder_map[[pest$eppoCode]]

  # No occurrence data
  no_data_file <- list.files(folder, pattern = "no_occurrence_data\\.txt$", recursive = TRUE, full.names = TRUE)[1]
  if (!is.na(no_data_file)) {
    cat("  ⚠️  No occurrence data - model could not be built\n\n")
    justification <- paste0("No Maxent model in folder. Reason: Insufficient occurrence data available for species distribution modeling. [Model folder: ", folder, "] [Source: VKM SDMtune/MaxEnt]")
    update_db(output_db, pest$idAssessment, justification)
    next
  }

  # Find files
  html_file <- list.files(folder, pattern = "\\.html$", recursive = TRUE, full.names = TRUE)[1]
  tiff_file <- list.files(folder, pattern = "map\\.tif$", recursive = TRUE, full.names = TRUE)[1]
  if (is.na(tiff_file)) {
    tiff_file <- list.files(folder, pattern = "\\.tif$", recursive = TRUE, full.names = TRUE)[1]
  }

  # Parse & analyze
  metrics <- if (!is.na(html_file)) parse_html(html_file) else list()
  tiff_result <- if (!is.na(tiff_file)) analyze_tiff(tiff_file) else NULL

  # Build justification
  justification <- build_justification(metrics, tiff_result, folder)

  # Report
  if (!is.null(tiff_result)) {
    if (tiff_result$norway_suitable || tiff_result$sweden_suitable) {
      cat("  ✅ SUITABLE HABITAT\n\n")
    } else {
      cat("  ❌ No suitable habitat (Norway:", round(tiff_result$max_norway, 3),
          "Sweden:", round(tiff_result$max_sweden, 3), ")\n\n")
    }
  } else {
    cat("  ⚠️  No TIFF found\n\n")
  }

  update_db(output_db, pest$idAssessment, justification)
}

cat("=== DONE ===\n")
cat("Output:", output_db, "\n")
