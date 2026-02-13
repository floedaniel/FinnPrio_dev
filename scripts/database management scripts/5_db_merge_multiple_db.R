
library(DBI)
library(RSQLite)
library(dplyr)
library(purrr)

# =============================================================================
# CONFIGURATION
# =============================================================================

# Input folder containing .db files
INPUT_FOLDER <- "./db merg test"

# Output database name (will be created in INPUT_FOLDER)
OUTPUT_DB <- "FinnPrio_merged_two.db"

# Merge Multiple FinnPrio Databases
# ==================================
# This script reads all .db files from a folder and merges them into one database

# =============================================================================
# FUNCTIONS
# =============================================================================

merge_databases <- function(input_folder, output_db_name) {
  
  # Find all .db files (excluding output if it exists)
  db_files <- list.files(input_folder, pattern = "\\.db$", full.names = TRUE)
  db_files <- db_files[!grepl(output_db_name, db_files)]  # Exclude output file
  
  if (length(db_files) == 0) {
    stop("No .db files found in ", input_folder)
  }
  
  cat("Found", length(db_files), "databases:\n")
  for (f in db_files) cat("  -", basename(f), "\n")
  cat("\n")
  
  # Output path
  output_path <- file.path(input_folder, output_db_name)
  
  # Remove existing output if exists
  if (file.exists(output_path)) {
    cat("Removing existing output database...\n")
    result <- file.remove(output_path)
    if (!result) {
      stop("Cannot remove existing output file. Close any programs using it and try again:\n  ", output_path)
    }
  }
  
  # Copy first database as template (to get schema and reference tables)
  cat("Creating output database from template...\n")
  file.copy(db_files[1], output_path)
  
  # Connect to output database
  con_out <- dbConnect(SQLite(), output_path)
  
  # Clear data tables (keep reference tables)
  cat("Clearing data tables...\n")
  dbExecute(con_out, "DELETE FROM simulationSummaries")
  dbExecute(con_out, "DELETE FROM simulations")
  dbExecute(con_out, "DELETE FROM pathwayAnswers")
  dbExecute(con_out, "DELETE FROM entryPathways")
  dbExecute(con_out, "DELETE FROM answers")
  dbExecute(con_out, "DELETE FROM threatXassessment")
  dbExecute(con_out, "DELETE FROM assessments")
  dbExecute(con_out, "DELETE FROM pests")
  dbExecute(con_out, "DELETE FROM assessors")
  
  # Reset dbStatus
  dbExecute(con_out, "UPDATE dbStatus SET inUse = 0, timeStamp = CURRENT_TIMESTAMP")
  
  # ==========================================================================
  # MERGE ASSESSORS (deduplicate by firstName + lastName)
  # ==========================================================================
  cat("\n=== Merging Assessors ===\n")
  
  all_assessors <- list()
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    assessors <- dbReadTable(con, "assessors")
    dbDisconnect(con)
    
    if (nrow(assessors) == 0) next  # Skip empty tables
    
    assessors$source_db <- basename(db_file)
    all_assessors[[db_file]] <- assessors
  }
  
  if (length(all_assessors) == 0) {
    stop("No assessors found in any database!")
  }
  
  all_assessors_df <- bind_rows(all_assessors)
  
  # Deduplicate by firstName + lastName (keep first occurrence)
  unique_assessors <- all_assessors_df %>%
    mutate(fullName = paste(firstName, lastName)) %>%
    group_by(fullName) %>%
    slice(1) %>%
    ungroup() %>%
    select(-fullName, -source_db) %>%
    mutate(new_idAssessor = row_number())
  
  # Create mapping: old IDs to new IDs
  assessor_mapping <- all_assessors_df %>%
    mutate(fullName = paste(firstName, lastName)) %>%
    left_join(
      unique_assessors %>% 
        mutate(fullName = paste(firstName, lastName)) %>%
        select(fullName, new_idAssessor),
      by = "fullName"
    ) %>%
    select(source_db, old_idAssessor = idAssessor, new_idAssessor)
  
  # Insert unique assessors
  for (i in 1:nrow(unique_assessors)) {
    dbExecute(con_out,
              "INSERT INTO assessors (firstName, lastName, email) VALUES (?, ?, ?)",
              params = list(
                unique_assessors$firstName[i],
                unique_assessors$lastName[i],
                unique_assessors$email[i]
              )
    )
    # Update the new_idAssessor with actual auto-generated ID
    unique_assessors$new_idAssessor[i] <- dbGetQuery(con_out, "SELECT last_insert_rowid() as id")$id
  }
  
  # Rebuild assessor mapping with actual IDs
  assessor_mapping <- all_assessors_df %>%
    mutate(fullName = paste(firstName, lastName)) %>%
    left_join(
      unique_assessors %>% 
        mutate(fullName = paste(firstName, lastName)) %>%
        select(fullName, new_idAssessor),
      by = "fullName"
    ) %>%
    select(source_db, old_idAssessor = idAssessor, new_idAssessor)
  
  cat("Merged", nrow(unique_assessors), "unique assessors\n")
  
  # ==========================================================================
  # MERGE PESTS (allow duplicates)
  # ==========================================================================
  cat("\n=== Merging Pests ===\n")
  
  pest_mapping <- data.frame(
    source_db = character(),
    old_idPest = integer(),
    new_idPest = integer(),
    stringsAsFactors = FALSE
  )
  
  new_pest_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    pests <- dbReadTable(con, "pests")
    dbDisconnect(con)
    
    if (nrow(pests) == 0) next
    
    for (i in 1:nrow(pests)) {
      pest <- pests[i, ]
      
      # Insert and let SQLite auto-generate ID
      dbExecute(con_out,
                "INSERT INTO pests (scientificName, eppoCode, synonyms, vernacularName, 
                            idTaxa, idQuarantineStatus, inEurope, gbifTaxonKey) 
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                params = list(
                  pest$scientificName,
                  pest$eppoCode,
                  pest$synonyms,
                  pest$vernacularName,
                  pest$idTaxa,
                  pest$idQuarantineStatus,
                  pest$inEurope,
                  pest$gbifTaxonKey
                )
      )
      
      # Get the auto-generated ID
      new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() as id")$id
      
      pest_mapping <- rbind(pest_mapping, data.frame(
        source_db = basename(db_file),
        old_idPest = pest$idPest,
        new_idPest = new_id
      ))
      
      new_pest_id <- new_pest_id + 1
    }
  }
  cat("Added", new_pest_id - 1, "pests (including duplicates)\n")
  
  # ==========================================================================
  # MERGE ASSESSMENTS
  # ==========================================================================
  cat("\n=== Merging Assessments ===\n")
  
  assessment_mapping <- data.frame(
    source_db = character(),
    old_idAssessment = integer(),
    new_idAssessment = integer(),
    stringsAsFactors = FALSE
  )
  
  new_assessment_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    assessments <- dbReadTable(con, "assessments")
    dbDisconnect(con)
    
    if (nrow(assessments) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(assessments)) {
      ass <- assessments[i, ]
      
      # Map old IDs to new IDs
      new_pest <- pest_mapping %>%
        filter(source_db == db_name, old_idPest == ass$idPest) %>%
        pull(new_idPest)
      
      new_assessor <- assessor_mapping %>%
        filter(source_db == db_name, old_idAssessor == ass$idAssessor) %>%
        pull(new_idAssessor) %>%
        unique()
      
      if (length(new_pest) == 0 || length(new_assessor) == 0) {
        cat("  Skipping assessment", ass$idAssessment, "- missing pest/assessor mapping\n")
        next
      }
      
      # Insert with new IDs
      dbExecute(con_out,
                "INSERT INTO assessments (idPest, idAssessor, startDate, endDate, 
                                  finished, valid, notes, version, hosts, 
                                  potentialEntryPathways, reference) 
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params = list(
                  new_pest[1],
                  new_assessor[1],
                  ass$startDate,
                  ass$endDate,
                  ass$finished,
                  ass$valid,
                  ass$notes,
                  ass$version,
                  ass$hosts,
                  ass$potentialEntryPathways,
                  ass$reference
                )
      )
      
      # Get the auto-generated ID
      new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() as id")$id
      
      assessment_mapping <- rbind(assessment_mapping, data.frame(
        source_db = db_name,
        old_idAssessment = ass$idAssessment,
        new_idAssessment = new_id
      ))
      
      new_assessment_id <- new_assessment_id + 1
    }
  }
  cat("Merged", new_assessment_id - 1, "assessments\n")
  
  # ==========================================================================
  # MERGE ANSWERS
  # ==========================================================================
  cat("\n=== Merging Answers ===\n")
  
  new_answer_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    answers <- dbReadTable(con, "answers")
    dbDisconnect(con)
    
    if (nrow(answers) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(answers)) {
      ans <- answers[i, ]
      
      new_assessment <- assessment_mapping %>%
        filter(source_db == db_name, old_idAssessment == ans$idAssessment) %>%
        pull(new_idAssessment)
      
      if (length(new_assessment) == 0) next
      
      dbExecute(con_out,
                "INSERT INTO answers (idAssessment, idQuestion, min, likely, max, justification) 
         VALUES (?, ?, ?, ?, ?, ?)",
                params = list(
                  new_assessment[1],
                  ans$idQuestion,
                  ans$min,
                  ans$likely,
                  ans$max,
                  ans$justification
                )
      )
      new_answer_id <- new_answer_id + 1
    }
  }
  cat("Merged", new_answer_id - 1, "answers\n")
  
  # ==========================================================================
  # MERGE ENTRY PATHWAYS
  # ==========================================================================
  cat("\n=== Merging Entry Pathways ===\n")
  
  entrypath_mapping <- data.frame(
    source_db = character(),
    old_idEntryPathway = integer(),
    new_idEntryPathway = integer(),
    stringsAsFactors = FALSE
  )
  
  new_entrypath_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    entrypaths <- dbReadTable(con, "entryPathways")
    dbDisconnect(con)
    
    if (nrow(entrypaths) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(entrypaths)) {
      ep <- entrypaths[i, ]
      
      new_assessment <- assessment_mapping %>%
        filter(source_db == db_name, old_idAssessment == ep$idAssessment) %>%
        pull(new_idAssessment)
      
      if (length(new_assessment) == 0) next
      
      # Get the new entry pathway ID after insert
      dbExecute(con_out,
                "INSERT INTO entryPathways (idAssessment, idPathway) 
         VALUES (?, ?)",
                params = list(
                  new_assessment[1],
                  ep$idPathway
                )
      )
      
      # Get the auto-generated ID
      new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() as id")$id
      
      entrypath_mapping <- rbind(entrypath_mapping, data.frame(
        source_db = db_name,
        old_idEntryPathway = ep$idEntryPathway,
        new_idEntryPathway = new_id
      ))
      
      new_entrypath_id <- new_entrypath_id + 1
    }
  }
  cat("Merged", new_entrypath_id - 1, "entry pathways\n")
  
  # ==========================================================================
  # MERGE PATHWAY ANSWERS
  # ==========================================================================
  cat("\n=== Merging Pathway Answers ===\n")
  
  new_pathans_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    pathans <- dbReadTable(con, "pathwayAnswers")
    dbDisconnect(con)
    
    if (nrow(pathans) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(pathans)) {
      pa <- pathans[i, ]
      
      new_entrypath <- entrypath_mapping %>%
        filter(source_db == db_name, old_idEntryPathway == pa$idEntryPathway) %>%
        pull(new_idEntryPathway)
      
      if (length(new_entrypath) == 0) next
      
      dbExecute(con_out,
                "INSERT INTO pathwayAnswers (idEntryPathway, idPathQuestion, 
                                     min, likely, max, justification) 
         VALUES (?, ?, ?, ?, ?, ?)",
                params = list(
                  new_entrypath[1],
                  pa$idPathQuestion,
                  pa$min,
                  pa$likely,
                  pa$max,
                  pa$justification
                )
      )
      new_pathans_id <- new_pathans_id + 1
    }
  }
  cat("Merged", new_pathans_id - 1, "pathway answers\n")
  
  # ==========================================================================
  # MERGE THREAT X ASSESSMENT
  # ==========================================================================
  cat("\n=== Merging Threat Associations ===\n")
  
  new_threat_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    threats <- dbReadTable(con, "threatXassessment")
    dbDisconnect(con)
    
    if (nrow(threats) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(threats)) {
      th <- threats[i, ]
      
      new_assessment <- assessment_mapping %>%
        filter(source_db == db_name, old_idAssessment == th$idAssessment) %>%
        pull(new_idAssessment)
      
      if (length(new_assessment) == 0) next
      
      dbExecute(con_out,
                "INSERT INTO threatXassessment (idAssessment, idThrSect) 
         VALUES (?, ?)",
                params = list(
                  new_assessment[1],
                  th$idThrSect
                )
      )
      new_threat_id <- new_threat_id + 1
    }
  }
  cat("Merged", new_threat_id - 1, "threat associations\n")
  
  # ==========================================================================
  # MERGE SIMULATIONS
  # ==========================================================================
  cat("\n=== Merging Simulations ===\n")
  
  simulation_mapping <- data.frame(
    source_db = character(),
    old_idSimulation = integer(),
    new_idSimulation = integer(),
    stringsAsFactors = FALSE
  )
  
  new_sim_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    sims <- dbReadTable(con, "simulations")
    dbDisconnect(con)
    
    if (nrow(sims) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(sims)) {
      sim <- sims[i, ]
      
      new_assessment <- assessment_mapping %>%
        filter(source_db == db_name, old_idAssessment == sim$idAssessment) %>%
        pull(new_idAssessment)
      
      if (length(new_assessment) == 0) next
      
      dbExecute(con_out,
                "INSERT INTO simulations (idAssessment, iterations, lambda, 
                                  weight1, weight2, date) 
         VALUES (?, ?, ?, ?, ?, ?)",
                params = list(
                  new_assessment[1],
                  sim$iterations,
                  sim$lambda,
                  sim$weight1,
                  sim$weight2,
                  sim$date
                )
      )
      
      # Get the auto-generated ID
      new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() as id")$id
      
      simulation_mapping <- rbind(simulation_mapping, data.frame(
        source_db = db_name,
        old_idSimulation = sim$idSimulation,
        new_idSimulation = new_id
      ))
      
      new_sim_id <- new_sim_id + 1
    }
  }
  cat("Merged", new_sim_id - 1, "simulations\n")
  
  # ==========================================================================
  # MERGE SIMULATION SUMMARIES
  # ==========================================================================
  cat("\n=== Merging Simulation Summaries ===\n")
  
  new_simsum_id <- 1
  
  for (db_file in db_files) {
    con <- dbConnect(SQLite(), db_file)
    simsums <- dbReadTable(con, "simulationSummaries")
    dbDisconnect(con)
    
    if (nrow(simsums) == 0) next
    
    db_name <- basename(db_file)
    
    for (i in 1:nrow(simsums)) {
      ss <- simsums[i, ]
      
      new_sim <- simulation_mapping %>%
        filter(source_db == db_name, old_idSimulation == ss$idSimulation) %>%
        pull(new_idSimulation)
      
      if (length(new_sim) == 0) next
      
      dbExecute(con_out,
                "INSERT INTO simulationSummaries (idSimulation, variable, 
                                          min, q5, q25, median, q75, q95, max, mean) 
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params = list(
                  new_sim[1],
                  ss$variable,
                  ss$min,
                  ss$q5,
                  ss$q25,
                  ss$median,
                  ss$q75,
                  ss$q95,
                  ss$max,
                  ss$mean
                )
      )
      new_simsum_id <- new_simsum_id + 1
    }
  }
  cat("Merged", new_simsum_id - 1, "simulation summaries\n")
  
# ==========================================================================
# DONE
# ==========================================================================
  
dbDisconnect(con_out)
  
cat("\n================================================================================\n")
cat("MERGE COMPLETE!\n")
cat("================================================================================\n")
cat("Output database:", output_path, "\n")
cat("\nSummary:\n")
cat("  - Assessors:", nrow(unique_assessors), "(deduplicated)\n")
cat("  - Pests:", new_pest_id - 1, "(including duplicates)\n")
cat("  - Assessments:", new_assessment_id - 1, "\n")
cat("  - Answers:", new_answer_id - 1, "\n")
cat("  - Entry Pathways:", new_entrypath_id - 1, "\n")
cat("  - Pathway Answers:", new_pathans_id - 1, "\n")
cat("  - Simulations:", new_sim_id - 1, "\n")
  
  return(output_path)
}

# =============================================================================
# RUN MERGE
# =============================================================================

 merge_databases(INPUT_FOLDER, OUTPUT_DB)
