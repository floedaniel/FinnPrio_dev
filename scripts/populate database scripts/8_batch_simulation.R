################################################################################
# FinnPRIO Batch Simulation Script
################################################################################
#
# Description:
#   Batch run Monte Carlo simulations for all assessments in a FinnPRIO database
#
# Usage:
#   source("scripts/populate database scripts/6_batch_simulation.R")
#
################################################################################

# Load required packages -------------------------------------------------------
library(DBI)
library(RSQLite)
library(tidyverse)
library(mc2d)      # For PERT distributions
library(lubridate)
library(glue)
library(jsonlite)  # For parsing question options from JSON

# Source required functions ----------------------------------------------------
source("R/simulations.R")
source("R/internal functions.R")  # For get_points_as_table()

# =============================================================================
# CONFIGURATION - EDIT THESE SETTINGS
# =============================================================================

# Database Path
#DB_PATH <- "python/outputs/old_test_ai_enhanced_03_02_2026.db"
#DB_PATH <- "databases/finnprio_assessments_database_2025/FinnPrio_fg9_batch_1_2025.db"

DB_PATH <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/finnprio_2026/master_database_2026/master_database_2026.db"

# Simulation Settings
ITERATIONS <- 50000  # Number of Monte Carlo iterations (default: 50000)
LAMBDA <- 5          # PERT distribution shape parameter (default: 1)
WEIGHT1 <- 0.5       # Weight for economic impact (IMP1 + IMP2)
WEIGHT2 <- 0.5       # Weight for environmental/social impact (IMP3 + IMP4)

# Processing Options
SKIP_EXISTING <- FALSE       # Skip assessments that already have simulations
ONLY_FINISHED <- FALSE       # Only process finished assessments
ONLY_VALID <- FALSE          # Only process valid assessments
SPECIFIC_ASSESSMENT <- NULL  # Set to assessment ID to process single assessment (e.g., 2)
                             # Or leave as NULL to process all

# =============================================================================
# END CONFIGURATION
# =============================================================================

# Helper Functions -------------------------------------------------------------

get_all_assessments <- function(con, only_finished = TRUE, only_valid = FALSE) {
  # Get list of assessments to process

  query <- "SELECT idAssessment, idPest FROM assessments WHERE 1=1"

  if (only_finished) {
    query <- paste(query, "AND finished = 1")
  }

  if (only_valid) {
    query <- paste(query, "AND valid = 1")
  }

  query <- paste(query, "ORDER BY idAssessment")

  assessments <- dbGetQuery(con, query)
  return(assessments)
}

assessment_has_simulation <- function(con, id_assessment) {
  # Check if assessment already has a simulation

  result <- dbGetQuery(con,
    "SELECT COUNT(*) as count FROM simulations WHERE idAssessment = ?",
    params = list(id_assessment))

  return(result$count > 0)
}

get_pest_name <- function(con, id_pest) {
  # Get pest scientific name

  result <- dbGetQuery(con,
    "SELECT scientificName FROM pests WHERE idPest = ?",
    params = list(id_pest))

  if (nrow(result) > 0) {
    return(result$scientificName)
  } else {
    return("Unknown")
  }
}

prepare_answers_data <- function(con, id_assessment, points_main) {
  # Prepare answers data frame for simulation (following server.R logic)

  # Get main answers
  answers_query <- "
    SELECT
      a.idAnswer,
      a.idAssessment,
      a.idQuestion,
      q.[group],
      q.number,
      q.subgroup,
      a.min,
      a.likely,
      a.max
    FROM answers a
    JOIN questions q ON a.idQuestion = q.idQuestion
    WHERE a.idAssessment = ?
  "

  answers_raw <- dbGetQuery(con, answers_query, params = list(id_assessment))

  if (nrow(answers_raw) == 0) {
    return(NULL)
  }

  # Process exactly like server.R (lines 1598-1626)
  answers_df <- answers_raw |>
    rename_with(tolower) |>
    mutate(question = paste0(group, number)) |>
    left_join(points_main, by = c("question" = "Question", "min" = "Option")) |>
    rename(min_points = Points) |>
    left_join(points_main, by = c("question" = "Question", "likely" = "Option")) |>
    rename(likely_points = Points) |>
    left_join(points_main, by = c("question" = "Question", "max" = "Option")) |>
    rename(max_points = Points) |>
    mutate(min_points = ifelse(is.na(min_points), 0, min_points),
           likely_points = ifelse(is.na(likely_points), 0, likely_points),
           max_points = ifelse(is.na(max_points), 0, max_points)) |>
    mutate(
      question = case_when(
        question %in% c("IMP2.1", "IMP2.2", "IMP2.3") ~ "IMP2",
        question %in% c("IMP4.1", "IMP4.2", "IMP4.3") ~ "IMP4",
        TRUE ~ question
      )
    ) |>
    group_by(question) |>
    summarise(
      min_points = sum(as.numeric(min_points), na.rm = TRUE),
      likely_points = sum(as.numeric(likely_points), na.rm = TRUE),
      max_points = sum(as.numeric(max_points), na.rm = TRUE),
      .groups = "drop"
    ) |>
    as.data.frame()

  # Check if IMP2 & IMP4 are present (lines 1629-1638)
  if (!"IMP2" %in% answers_df$question) {
    answers_df <- rbind(answers_df, data.frame(question = "IMP2", min_points = 0, likely_points = 0, max_points = 0))
  }
  if (!"IMP4" %in% answers_df$question) {
    answers_df <- rbind(answers_df, data.frame(question = "IMP4", min_points = 0, likely_points = 0, max_points = 0))
  }

  return(answers_df)
}

prepare_pathway_answers_data <- function(con, id_assessment, points_entry) {
  # Prepare pathway answers data frame for simulation (following server.R logic)

  # Get pathway answers
  pathway_query <- "
    SELECT
      pa.idPathAnswer,
      ep.idAssessment,
      ep.idPathway as idpathway,
      pq.[group],
      pq.number,
      pa.min,
      pa.likely,
      pa.max
    FROM pathwayAnswers pa
    JOIN entryPathways ep ON pa.idEntryPathway = ep.idEntryPathway
    JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
    WHERE ep.idAssessment = ?
  "

  pathway_raw <- dbGetQuery(con, pathway_query, params = list(id_assessment))

  if (nrow(pathway_raw) == 0) {
    return(NULL)
  }

  # Process exactly like server.R (lines 1640-1653)
  answers_entry_df <- pathway_raw |>
    rename_with(tolower) |>
    mutate(question = paste0(group, number)) |>
    left_join(points_entry, by = c("question" = "Question", "min" = "Option")) |>
    rename(min_points = Points) |>
    left_join(points_entry, by = c("question" = "Question", "likely" = "Option")) |>
    rename(likely_points = Points) |>
    left_join(points_entry, by = c("question" = "Question", "max" = "Option")) |>
    rename(max_points = Points) |>
    mutate(min_points = ifelse(is.na(min_points), 0, min_points),
           likely_points = ifelse(is.na(likely_points), 0, likely_points),
           max_points = ifelse(is.na(max_points), 0, max_points))

  return(answers_entry_df)
}

run_simulation_for_assessment <- function(con, id_assessment, id_pest,
                                         iterations, lambda, w1, w2,
                                         points_main, points_entry) {
  # Run simulation for a single assessment and save results

  pest_name <- get_pest_name(con, id_pest)

  cat(sprintf("  Pest: %s\n", pest_name))
  cat(sprintf("  Loading data... "))

  # Prepare data using same logic as server.R
  answers_df <- prepare_answers_data(con, id_assessment, points_main)
  answers_entry_df <- prepare_pathway_answers_data(con, id_assessment, points_entry)
  pathways_df <- dbReadTable(con, "pathways")

  if (is.null(answers_df)) {
    cat("FAILED\n")
    cat("  ⚠️  No answers found\n")
    return(FALSE)
  }

  if (is.null(answers_entry_df)) {
    cat("FAILED\n")
    cat("  ⚠️  No pathway answers found\n")
    return(FALSE)
  }

  cat("OK\n")
  cat(sprintf("  Running simulation (%d iterations)... ", iterations))

  # Run simulation
  tryCatch({
    results <- simulation(answers_df, answers_entry_df, pathways_df,
                         iterations = iterations, lambda = lambda,
                         w1 = w1, w2 = w2)

    cat("OK\n")
    cat("  Calculating summary statistics... ")

    # Calculate summary statistics
    safe_min <- function(x) { r <- min(x, na.rm = TRUE); if (is.infinite(r)) NA_real_ else round(r, 3) }
    safe_max <- function(x) { r <- max(x, na.rm = TRUE); if (is.infinite(r)) NA_real_ else round(r, 3) }

    summary_df <- results |>
      as.data.frame() |>
      reframe(across(everything(), list(
        min    = ~safe_min(.x),
        q5     = ~quantile(.x, 0.05, na.rm = TRUE) |> round(3),
        q25    = ~quantile(.x, 0.25, na.rm = TRUE) |> round(3),
        median = ~quantile(.x, 0.50, na.rm = TRUE) |> round(3),
        q75    = ~quantile(.x, 0.75, na.rm = TRUE) |> round(3),
        q95    = ~quantile(.x, 0.95, na.rm = TRUE) |> round(3),
        max    = ~safe_max(.x),
        mean   = ~mean(.x, na.rm = TRUE) |> round(3)
      ), .names = "{.col}_{.fn}")) |>
      pivot_longer(cols = everything(),
                   names_to = c("variable", "stat"),
                   names_sep = "_",
                   values_to = "value") |>
      pivot_wider(names_from = stat, values_from = value) |>
      as.data.frame()

    cat("OK\n")
    cat("  Saving to database... ")

    # Insert simulation metadata
    dbExecute(con,
      "INSERT INTO simulations(idAssessment, iterations, lambda, weight1, weight2, date)
       VALUES(?,?,?,?,?,?)",
      params = list(id_assessment, iterations, lambda, w1, w2,
                   format(now("UTC"), "%Y-%m-%d %H:%M:%S")))

    # Get simulation ID
    sim_id <- dbGetQuery(con, "SELECT last_insert_rowid() AS idSimulation") |>
      pull(idSimulation)

    # Add simulation ID to summary and save
    summary_df <- summary_df |>
      mutate(idSimulation = sim_id) |>
      select(idSimulation, everything())

    dbWriteTable(con, "simulationSummaries", summary_df, append = TRUE, row.names = FALSE)

    cat("OK\n")
    cat(sprintf("  ✅ Simulation saved (ID: %d)\n", sim_id))

    return(TRUE)

  }, error = function(e) {
    cat("FAILED\n")
    cat(sprintf("  ❌ Error: %s\n", conditionMessage(e)))
    return(FALSE)
  })
}

# Main Execution ---------------------------------------------------------------

main <- function() {

  cat("\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat("FinnPRIO BATCH SIMULATION\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")

  # Check database exists
  if (!file.exists(DB_PATH)) {
    cat(sprintf("\n❌ Database not found: %s\n", DB_PATH))
    return()
  }

  cat(sprintf("\nDatabase: %s\n", DB_PATH))
  cat(sprintf("Settings: iterations=%d, lambda=%.1f, w1=%.2f, w2=%.2f\n",
              ITERATIONS, LAMBDA, WEIGHT1, WEIGHT2))
  cat(sprintf("Options: skip_existing=%s, only_finished=%s, only_valid=%s\n",
              SKIP_EXISTING, ONLY_FINISHED, ONLY_VALID))

  # Connect to database
  con <- dbConnect(RSQLite::SQLite(), DB_PATH)
  on.exit(dbDisconnect(con))

  # Load questions and build points lookup tables (like server.R does)
  cat("\nℹ️  Building points lookup tables... ")

  questions_main <- dbGetQuery(con, "SELECT * FROM questions")
  questions_entry <- dbGetQuery(con, "SELECT * FROM pathwayQuestions")

  points_main <- get_points_as_table(questions_main)
  points_entry <- get_points_as_table(questions_entry)

  cat("OK\n")

  # Get assessments to process
  if (!is.null(SPECIFIC_ASSESSMENT)) {
    cat(sprintf("\nℹ️  Processing single assessment: %d\n", SPECIFIC_ASSESSMENT))

    assessment_info <- dbGetQuery(con,
      "SELECT idAssessment, idPest FROM assessments WHERE idAssessment = ?",
      params = list(SPECIFIC_ASSESSMENT))

    if (nrow(assessment_info) == 0) {
      cat(sprintf("❌ Assessment %d not found\n", SPECIFIC_ASSESSMENT))
      return()
    }

    assessments <- assessment_info
  } else {
    assessments <- get_all_assessments(con, ONLY_FINISHED, ONLY_VALID)
    cat(sprintf("\nℹ️  Found %d assessment(s) to process\n", nrow(assessments)))
  }

  if (nrow(assessments) == 0) {
    cat("\n⚠️  No assessments to process!\n")
    return()
  }

  # Process each assessment
  cat("\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat("PROCESSING ASSESSMENTS\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n\n")

  success_count <- 0
  skipped_count <- 0
  failed_count <- 0

  for (i in 1:nrow(assessments)) {
    id_assessment <- assessments$idAssessment[i]
    id_pest <- assessments$idPest[i]

    cat(sprintf("[%d/%d] Assessment %d\n", i, nrow(assessments), id_assessment))

    # Check if already has simulation
    if (SKIP_EXISTING && assessment_has_simulation(con, id_assessment)) {
      cat("  ⏭️  Skipped (already has simulation)\n\n")
      skipped_count <- skipped_count + 1
      next
    }

    # Run simulation
    success <- run_simulation_for_assessment(con, id_assessment, id_pest,
                                             ITERATIONS, LAMBDA, WEIGHT1, WEIGHT2,
                                             points_main, points_entry)

    if (success) {
      success_count <- success_count + 1
    } else {
      failed_count <- failed_count + 1
    }

    cat("\n")
  }

  # Summary
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat("COMPLETE\n")
  cat("=" |> rep(80) |> paste(collapse = ""), "\n")
  cat(sprintf("\nTotal assessments: %d\n", nrow(assessments)))
  cat(sprintf("  ✅ Success: %d\n", success_count))
  cat(sprintf("  ⏭️  Skipped: %d\n", skipped_count))
  cat(sprintf("  ❌ Failed:  %d\n", failed_count))
  cat("\n")
}

# Run the script ---------------------------------------------------------------
main()
