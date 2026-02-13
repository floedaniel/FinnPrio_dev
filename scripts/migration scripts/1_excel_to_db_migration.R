################################################################################
# FinnPRIO Excel to SQLite Database Migration Script
################################################################################

library(DBI)
library(RSQLite)
library(tidyverse)
library(readxl)
library(lubridate)
library(jsonlite)

# Excel input -------------------------------------------------------------

EXCEL_FILE <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/VKM Data/26.08.2024_lopende_oppdrag_plantehelse/data/6_FinnPRIO master/Assesments/Mogens Nicolaisen/batch_2/FinnPRIO_Mogens_Nicolaisen_BGMV00.xlsm"

# Configuration ----------------------------------------------------------------
DB_FILE <- "./Finnprio assesments 2025 db/FinnPrio_DB_2025.db"
EXCEL_TAB <- "Assessment database"

# Assessments to SKIP (will not be migrated)
SKIP_SPECIES <- c(
  "TEST ASSESSMENT1 - NEVER DELETE THIS ONE!"
)

# Helper Functions -------------------------------------------------------------

safe_str <- function(val) {
  if (is.null(val) || is.na(val) || length(val) == 0) return(NA_character_)
  as.character(val)
}

safe_int <- function(val, default = NA_integer_) {
  if (is.null(val) || is.na(val) || length(val) == 0) return(default)
  tryCatch(as.integer(val), error = function(e) default)
}

extract_date <- function(species_date_str) {
  if (is.na(species_date_str)) return(NA_character_)
  match <- str_match(species_date_str, "(\\d{2})\\.(\\d{2})\\.(\\d{4})")
  if (!is.na(match[1, 1])) {
    return(sprintf("%s-%s-%s", match[1, 4], match[1, 3], match[1, 2]))
  }
  NA_character_
}

extract_species <- function(species_date_str) {
  if (is.na(species_date_str)) return(NA_character_)
  match <- str_match(species_date_str, "^(.+?)\\s*/\\s*\\d{2}\\.\\d{2}\\.\\d{4}")
  if (!is.na(match[1, 2])) {
    return(trimws(match[1, 2]))
  }
  trimws(species_date_str)
}

extract_eppo <- function(species_date_str) {
  if (is.na(species_date_str)) return(NA_character_)
  match <- str_match(species_date_str, "\\(([A-Z0-9]{5,6})\\)")
  if (!is.na(match[1, 2])) return(match[1, 2])
  NA_character_
}

get_col_value <- function(row, col_name, df_cols) {
  if (col_name %in% df_cols) return(row[[col_name]])
  col_space <- paste0(col_name, " ")
  if (col_space %in% df_cols) return(row[[col_space]])
  col_trim <- trimws(col_name)
  if (col_trim %in% df_cols) return(row[[col_trim]])
  NA
}

get_max_id <- function(con, table, id_col) {
  result <- dbGetQuery(con, sprintf("SELECT MAX(%s) as max_id FROM %s", id_col, table))
  if (is.na(result$max_id)) return(0)
  result$max_id
}

# Points-to-Option Lookup Functions -------------------------------------------

build_points_to_option_lookup <- function(con, question_code, table = "questions") {
  # Parse question code: "ENT1" -> group="ENT", number="1"
  parts <- str_match(question_code, "^([A-Z]+)(\\d+.*)")
  if (is.na(parts[1])) return(NULL)

  group <- parts[2]
  number <- parts[3]

  # Query for the question's JSON list
  result <- dbGetQuery(con,
    sprintf("SELECT list FROM %s WHERE [group] = ? AND number = ?", table),
    params = list(group, number))

  if (nrow(result) == 0) {
    warning(sprintf("Question not found: %s", question_code))
    return(NULL)
  }

  # Parse JSON: [{"opt": "a", "text": "...", "points": 1}, ...]
  options_list <- fromJSON(result$list[1])

  # Build lookup: points -> option code
  lookup <- setNames(options_list$opt, as.character(options_list$points))
  return(lookup)
}

convert_excel_to_option_code <- function(excel_value, points_lookup) {
  if (is.na(excel_value) || length(excel_value) == 0) {
    return(NA_character_)
  }

  value_str <- as.character(excel_value)
  option_code <- points_lookup[[value_str]]

  if (is.null(option_code)) {
    warning(sprintf("No option found for points value: %s", value_str))
    return(NA_character_)
  }

  return(option_code)
}

# Main Migration ---------------------------------------------------------------

# Read Excel
cat(sprintf("Reading Excel file: %s\n", EXCEL_FILE))
excel_data <- read_excel(EXCEL_FILE, sheet = EXCEL_TAB)
df_cols <- names(excel_data)
cat(sprintf("Loaded %d assessments with %d columns\n\n", nrow(excel_data), ncol(excel_data)))

# Connect to database
cat(sprintf("Connecting to database: %s\n", DB_FILE))
con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Load reference tables
cat("Loading reference tables...\n")

pathway_df <- dbGetQuery(con, "SELECT idPathway, name FROM pathways")
pathway_lookup <- setNames(pathway_df$idPathway, pathway_df$name)
cat(sprintf("  Pathways: %s\n", paste(pathway_df$name, collapse = ", ")))

taxa_df <- dbGetQuery(con, "SELECT idTaxa, name FROM taxonomicGroups")
cat(sprintf("  Taxonomic groups: %s\n", paste(taxa_df$name, collapse = ", ")))

quarantine_df <- dbGetQuery(con, "SELECT idQuarantineStatus, name FROM quarantineStatus")
quarantine_lookup <- setNames(quarantine_df$idQuarantineStatus, quarantine_df$name)
cat(sprintf("  Quarantine statuses: %s\n", paste(quarantine_df$name, collapse = ", ")))

sector_df <- dbGetQuery(con, "SELECT idThrSect, threatGroup, name FROM threatenedSectors")
sector_lookup <- setNames(sector_df$idThrSect, sector_df$name)
cat(sprintf("  Threatened sectors: %s\n", paste(sector_df$name, collapse = ", ")))

questions_df <- dbGetQuery(con, "SELECT idQuestion, [group], subGroup, number FROM questions")
cat(sprintf("  Questions: %d entries\n", nrow(questions_df)))

pathway_questions_df <- dbGetQuery(con, "SELECT idPathQuestion, [group], subGroup, number FROM pathwayQuestions")
cat(sprintf("  Pathway questions: %d entries\n", nrow(pathway_questions_df)))

# Build taxonomicGroups lookup - Excel uses short names, DB has full names with EPPO codes
# Map Excel column names to DB idTaxa
taxa_excel_to_id <- list(
  "Insects" = taxa_df$idTaxa[grepl("Insects", taxa_df$name)],
  "Mites" = taxa_df$idTaxa[grepl("Mites", taxa_df$name)],
  "Nematodes" = taxa_df$idTaxa[grepl("Nematodes", taxa_df$name)],
  "Bacterium and phytoplasma" = taxa_df$idTaxa[grepl("Bacteria", taxa_df$name)],
  "Fungi and fungus-like" = taxa_df$idTaxa[grepl("Fungi", taxa_df$name)],
  "Viruses and viroids" = taxa_df$idTaxa[grepl("Viruses", taxa_df$name)],
  "Invasive plants" = taxa_df$idTaxa[grepl("Invasive", taxa_df$name)]
)
cat("  Taxa Excel->DB mapping created\n")

# Build question lookup: "ENT1" -> idQuestion, "IMP2.1" -> idQuestion
# Key = group + number (number already contains "2.1", "4.1" etc.)
question_lookup <- list()
for (i in seq_len(nrow(questions_df))) {
  grp <- questions_df$group[i]
  num <- questions_df$number[i]
  id_q <- questions_df$idQuestion[i]
  key <- paste0(grp, num)
  question_lookup[[key]] <- id_q
}
cat(sprintf("  Question keys: %s\n", paste(names(question_lookup), collapse = ", ")))

# Build pathway question lookup: "ENT2A" -> idPathQuestion
path_question_lookup <- list()
for (i in seq_len(nrow(pathway_questions_df))) {
  grp <- pathway_questions_df$group[i]
  num <- pathway_questions_df$number[i]
  id_pq <- pathway_questions_df$idPathQuestion[i]
  key <- paste0(grp, num)
  path_question_lookup[[key]] <- id_pq
}
cat(sprintf("  Pathway question keys: %s\n", paste(names(path_question_lookup), collapse = ", ")))

# Build points-to-option lookup tables -----------------------------------------
cat("\nBuilding points-to-option lookup tables...\n")

# Build lookups for main questions
question_lookups <- list()
for (code in c("ENT1", "EST1", "EST2", "EST3", "EST4", "IMP1", "IMP3",
               "MAN1", "MAN2", "MAN3", "MAN4", "MAN5")) {
  question_lookups[[code]] <- build_points_to_option_lookup(con, code, "questions")
  if (!is.null(question_lookups[[code]])) {
    cat(sprintf("  %s: %s\n", code, paste(names(question_lookups[[code]]), "->", question_lookups[[code]], collapse=", ")))
  }
}

# Build lookups for pathway questions
pathway_lookups <- list()
for (code in c("ENT2A", "ENT2B", "ENT3", "ENT4")) {
  pathway_lookups[[code]] <- build_points_to_option_lookup(con, code, "pathwayQuestions")
  if (!is.null(pathway_lookups[[code]])) {
    cat(sprintf("  %s: %s\n", code, paste(names(pathway_lookups[[code]]), "->", pathway_lookups[[code]], collapse=", ")))
  }
}

# Get next available IDs
next_pest_id <- get_max_id(con, "pests", "idPest") + 1
next_assessment_id <- get_max_id(con, "assessments", "idAssessment") + 1
next_assessor_id <- get_max_id(con, "assessors", "idAssessor") + 1
next_entry_pathway_id <- get_max_id(con, "entryPathways", "idEntryPathway") + 1
next_answer_id <- get_max_id(con, "answers", "idAnswer") + 1
next_path_answer_id <- get_max_id(con, "pathwayAnswers", "idPathAnswer") + 1
next_threat_id <- get_max_id(con, "threatXassessment", "idThreat") + 1

cat(sprintf("\nStarting IDs: pest=%d, assessment=%d, assessor=%d\n",
            next_pest_id, next_assessment_id, next_assessor_id))

# Load existing assessors
existing_assessors <- dbGetQuery(con, "SELECT idAssessor, firstName, lastName FROM assessors")
assessor_lookup <- list()
for (i in seq_len(nrow(existing_assessors))) {
  full_name <- paste(existing_assessors$firstName[i], existing_assessors$lastName[i])
  assessor_lookup[[trimws(full_name)]] <- existing_assessors$idAssessor[i]
}

cat("\n================================================================================\n")
cat("Migrating assessments...\n")
cat("================================================================================\n")

skipped_count <- 0

for (i in 1:nrow(excel_data)) {
  row <- excel_data[i, ]
  
  species_date <- row$`Species/date`
  species_name <- extract_species(species_date)
  
  # === SKIP CHECK ===
  if (!is.na(species_name) && species_name %in% SKIP_SPECIES) {
    cat(sprintf("\n[%d/%d] SKIPPED: %s\n", i, nrow(excel_data), species_name))
    skipped_count <- skipped_count + 1
    next
  }
  
  eppo_code <- extract_eppo(species_date)
  assessment_date <- extract_date(species_date)
  
  if (is.na(assessment_date)) {
    date_val <- row$Date
    if (!is.na(date_val)) {
      assessment_date <- format(as.Date(date_val), "%Y-%m-%d")
    } else {
      assessment_date <- format(Sys.Date(), "%Y-%m-%d")
    }
  }
  
  cat(sprintf("\n[%d/%d] %s\n", i, nrow(excel_data), species_name))
  
  # === ASSESSOR ===
  assessor_name <- safe_str(row$Assessor)
  id_assessor <- NA_integer_
  if (!is.na(assessor_name)) {
    if (is.null(assessor_lookup[[assessor_name]])) {
      parts <- strsplit(assessor_name, " ")[[1]]
      first_name <- if (length(parts) > 0) parts[1] else ""
      last_name <- if (length(parts) > 1) paste(parts[-1], collapse = " ") else ""
      dbExecute(con, "INSERT INTO assessors (idAssessor, firstName, lastName, email) VALUES (?, ?, ?, ?)",
                params = list(next_assessor_id, first_name, last_name, NA_character_))
      assessor_lookup[[assessor_name]] <- next_assessor_id
      cat(sprintf("  New assessor: %s (ID: %d)\n", assessor_name, next_assessor_id))
      next_assessor_id <- next_assessor_id + 1
    }
    id_assessor <- assessor_lookup[[assessor_name]]
  }
  
  # === TAXONOMIC GROUP ===
  id_taxa <- NA_integer_
  taxa_excel_cols <- c("Insects", "Mites", "Nematodes", "Bacterium and phytoplasma",
                       "Fungi and fungus-like", "Viruses and viroids", "Invasive plants")
  
  for (excel_col in taxa_excel_cols) {
    val <- get_col_value(row, excel_col, df_cols)
    if (!is.na(val) && safe_int(val) == 1) {
      matched_id <- taxa_excel_to_id[[excel_col]]
      if (length(matched_id) > 0 && !is.na(matched_id[1])) {
        id_taxa <- matched_id[1]
        cat(sprintf("  Taxa: %s (ID: %d)\n", excel_col, id_taxa))
        break
      }
    }
  }
  
  # === QUARANTINE STATUS ===
  id_quarantine <- NA_integer_
  quar_status <- safe_str(row$`Quarantine status`)
  if (!is.na(quar_status) && quar_status %in% names(quarantine_lookup)) {
    id_quarantine <- quarantine_lookup[[quar_status]]
    cat(sprintf("  Quarantine: %s (ID: %d)\n", quar_status, id_quarantine))
  }
  
  # === PEST ENTRY ===
  common_name <- safe_str(row$`Common name`)
  synonyms <- safe_str(row$Synonims)
  host_plants <- safe_str(row$`Host plants`)
  
  ent1_val <- get_col_value(row, "ENT1 likely", df_cols)
  in_europe <- if (!is.na(ent1_val) && safe_int(ent1_val) >= 1) 1L else 0L
  
  # pests table has gbifTaxonKey column
  dbExecute(con, "INSERT INTO pests (idPest, scientificName, eppoCode, synonyms, vernacularName, idTaxa, idQuarantineStatus, inEurope, gbifTaxonKey) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params = list(next_pest_id, species_name, eppo_code, synonyms,
                          common_name, id_taxa, id_quarantine, in_europe, NA_character_))
  
  # === ASSESSMENT ENTRY ===
  # potentialEntryPathways is TEXT in DB
  potential_pathways_text <- NA_character_
  pw_names <- c()
  for (pw_num in 1:5) {
    pw_col <- sprintf("PW%d", pw_num)
    pw_val <- get_col_value(row, pw_col, df_cols)
    if (!is.na(pw_val) && trimws(as.character(pw_val)) != "") {
      pw_names <- c(pw_names, trimws(as.character(pw_val)))
    }
  }
  if (length(pw_names) > 0) {
    potential_pathways_text <- paste(pw_names, collapse = ", ")
  }
  
  references <- safe_str(row$References)
  
  dbExecute(con, "INSERT INTO assessments (idAssessment, idPest, idAssessor, startDate, endDate, finished, valid, hosts, potentialEntryPathways, reference, notes, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params = list(next_assessment_id, next_pest_id, id_assessor, assessment_date, assessment_date,
                          1L, 1L, host_plants, potential_pathways_text, references, NA_character_, "1"))
  
  # === ENTRY PATHWAYS ===
  entry_pathway_ids <- list()
  pathways_added <- c()
  
  for (pw_num in 1:5) {
    pw_col <- sprintf("PW%d", pw_num)
    pw_name <- get_col_value(row, pw_col, df_cols)
    if (!is.na(pw_name) && trimws(as.character(pw_name)) != "") {
      pw_name_str <- trimws(as.character(pw_name))
      if (pw_name_str %in% names(pathway_lookup)) {
        id_pathway <- pathway_lookup[[pw_name_str]]
        
        if (id_pathway %in% pathways_added) {
          cat(sprintf("  Pathway %d: %s (skipped - duplicate)\n", pw_num, pw_name_str))
          next
        }
        
        dbExecute(con, "INSERT INTO entryPathways (idEntryPathway, idAssessment, idPathway) VALUES (?, ?, ?)",
                  params = list(next_entry_pathway_id, next_assessment_id, id_pathway))
        entry_pathway_ids[[as.character(pw_num)]] <- next_entry_pathway_id
        pathways_added <- c(pathways_added, id_pathway)
        cat(sprintf("  Pathway %d: %s (ID: %d)\n", pw_num, pw_name_str, id_pathway))
        next_entry_pathway_id <- next_entry_pathway_id + 1
      } else {
        cat(sprintf("  WARNING: Pathway not found: '%s'\n", pw_name_str))
      }
    }
  }
  
  # === THREATENED SECTORS ===
  # DB sectors: Conifers, Broadleaves, Fruits, Berries, Potato, Sugar beet, Vegetables, etc.
  # Excel columns need to be mapped - check what columns exist in Excel
  # For now, try common patterns
  sector_col_mapping <- list(
    # Try various Excel column name patterns -> DB sector name
    "Conifers(likely)" = "Conifers",
    "Broadleaves(likely)" = "Broadleaves",
    "Fruits(likely)" = "Fruits",
    "Berries(likely)" = "Berries",
    "Potato(likely)" = "Potato",
    "Sugar beet(likely)" = "Sugar beet",
    "Vegetables(likely)" = "Vegetables",
    "Other open-field crops(likely)" = "Other open-field crops",
    "Cucumber(likely)" = "Cucumber",
    "Tomato(likely)" = "Tomato",
    "Pepper(likely)" = "Pepper",
    "Lettuce(likely)" = "Lettuce",
    "Ornamentals(likely)" = "Ornamentals",
    "Others(likely)" = "Others"
  )
  
  sectors_added <- c()
  for (excel_col in names(sector_col_mapping)) {
    val <- get_col_value(row, excel_col, df_cols)
    if (!is.na(val) && safe_int(val) == 1) {
      sector_name <- sector_col_mapping[[excel_col]]
      if (sector_name %in% names(sector_lookup)) {
        id_sector <- sector_lookup[[sector_name]]
        if (!(id_sector %in% sectors_added)) {
          dbExecute(con, "INSERT INTO threatXassessment (idThreat, idAssessment, idThrSect, mostLikely) VALUES (?, ?, ?, ?)",
                    params = list(next_threat_id, next_assessment_id, id_sector, 1L))
          sectors_added <- c(sectors_added, id_sector)
          next_threat_id <- next_threat_id + 1
        }
      }
    }
  }
  if (length(sectors_added) > 0) {
    cat(sprintf("  Threatened sectors: %d\n", length(sectors_added)))
  }
  
  # === MAIN QUESTION ANSWERS ===
  # Note: EST1 and EST2 justifications are SWAPPED in Excel GUI!
  main_questions <- list(
    list(code = "ENT1", min = "ENT1 min", likely = "ENT1 likely", max = "ENT1 max", just = "ENT1 Justification"),
    list(code = "EST1", min = "EST1 min", likely = "EST1 likely", max = "EST1 max", just = "EST2 Justification"),
    list(code = "EST2", min = "EST2 min", likely = "EST2 likely", max = "EST2 max", just = "EST1 Justification"),
    list(code = "EST3", min = "EST3 min", likely = "EST3 likely", max = "EST3 max", just = "EST3 Justification"),
    list(code = "EST4", min = "EST4 min", likely = "EST4 likely", max = "EST4 max", just = "EST4 Justification"),
    list(code = "IMP1", min = "IMP1 min", likely = "IMP1 likely", max = "IMP1 max", just = "IMP1 Justification"),
    list(code = "IMP3", min = "IMP3 min", likely = "IMP3 likely", max = "IMP3 max", just = "IMP3 Justification"),
    list(code = "MAN1", min = "MAN1 min", likely = "MAN1 likely", max = "MAN1 max", just = NULL),
    list(code = "MAN2", min = "MAN2 min", likely = "MAN2 likely", max = "MAN2 max", just = "MAN2 Justification"),
    list(code = "MAN3", min = "MAN3 min", likely = "MAN3 likely", max = "MAN3 max", just = "MAN3 Justification"),
    list(code = "MAN4", min = "MAN4 min", likely = "MAN4 likely", max = "MAN4 max", just = "MAN4 Justification"),
    list(code = "MAN5", min = "MAN5 min", likely = "MAN5 likely", max = "MAN5 max", just = "MAN5 Justification")
  )
  
  answers_added <- 0
  for (q in main_questions) {
    id_question <- question_lookup[[q$code]]
    if (is.null(id_question)) {
      cat(sprintf("  WARNING: Question not found: %s\n", q$code))
      next
    }

    # Read Excel values (numeric)
    min_val <- get_col_value(row, q$min, df_cols)
    likely_val <- get_col_value(row, q$likely, df_cols)
    max_val <- get_col_value(row, q$max, df_cols)
    just_val <- if (!is.null(q$just)) get_col_value(row, q$just, df_cols) else NA

    # Get the lookup table for this question
    lookup <- question_lookups[[q$code]]
    if (is.null(lookup)) {
      cat(sprintf("  WARNING: No lookup table for: %s\n", q$code))
      next
    }

    # Convert numeric values to option codes
    min_opt <- convert_excel_to_option_code(min_val, lookup)
    likely_opt <- convert_excel_to_option_code(likely_val, lookup)
    max_opt <- convert_excel_to_option_code(max_val, lookup)

    # Insert only if at least one value exists
    if (!all(is.na(c(min_opt, likely_opt, max_opt)))) {
      dbExecute(con, "INSERT INTO answers (idAnswer, idAssessment, idQuestion, min, likely, max, justification) VALUES (?, ?, ?, ?, ?, ?, ?)",
                params = list(next_answer_id, next_assessment_id, id_question,
                              safe_str(min_opt), safe_str(likely_opt), safe_str(max_opt), safe_str(just_val)))
      next_answer_id <- next_answer_id + 1
      answers_added <- answers_added + 1
    }
  }
  
  # === IMP2 BINARY QUESTIONS ===
  # Excel columns: "IMP2_Question1likely" -> answer code "a", "b", or "c"
  imp2_just <- safe_str(get_col_value(row, "IMP2 Justification", df_cols))
  imp2_questions <- list(
    list(code = "IMP2.1", base = "IMP2_Question1", answer_code = "a"),
    list(code = "IMP2.2", base = "IMP2_Question2", answer_code = "b"),
    list(code = "IMP2.3", base = "IMP2_Question3", answer_code = "c")
  )
  
  for (q in imp2_questions) {
    id_question <- question_lookup[[q$code]]
    if (is.null(id_question)) {
      cat(sprintf("  WARNING: Question not found: %s\n", q$code))
      next
    }
    
    likely_val <- get_col_value(row, paste0(q$base, "likely"), df_cols)
    min_val <- get_col_value(row, paste0(q$base, "min"), df_cols)
    max_val <- get_col_value(row, paste0(q$base, "max"), df_cols)
    
    likely_ans <- if (!is.na(likely_val) && safe_int(likely_val) == 1) q$answer_code else NA_character_
    min_ans <- if (!is.na(min_val) && safe_int(min_val) == 1) q$answer_code else NA_character_
    max_ans <- if (!is.na(max_val) && safe_int(max_val) == 1) q$answer_code else NA_character_
    
    if (!all(is.na(c(likely_ans, min_ans, max_ans)))) {
      just <- if (q$code == "IMP2.1") imp2_just else NA_character_
      dbExecute(con, "INSERT INTO answers (idAnswer, idAssessment, idQuestion, min, likely, max, justification) VALUES (?, ?, ?, ?, ?, ?, ?)",
                params = list(next_answer_id, next_assessment_id, id_question,
                              min_ans, likely_ans, max_ans, just))
      next_answer_id <- next_answer_id + 1
      answers_added <- answers_added + 1
    }
  }
  
  # === IMP4 BINARY QUESTIONS ===
  imp4_just <- safe_str(get_col_value(row, "IMP4 Justification", df_cols))
  imp4_questions <- list(
    list(code = "IMP4.1", base = "IMP4_Question1", answer_code = "a"),
    list(code = "IMP4.2", base = "IMP4_Question2", answer_code = "b"),
    list(code = "IMP4.3", base = "IMP4_Question3", answer_code = "c")
  )
  
  for (q in imp4_questions) {
    id_question <- question_lookup[[q$code]]
    if (is.null(id_question)) {
      cat(sprintf("  WARNING: Question not found: %s\n", q$code))
      next
    }
    
    likely_val <- get_col_value(row, paste0(q$base, "likely"), df_cols)
    min_val <- get_col_value(row, paste0(q$base, "min"), df_cols)
    max_val <- get_col_value(row, paste0(q$base, "max"), df_cols)
    
    likely_ans <- if (!is.na(likely_val) && safe_int(likely_val) == 1) q$answer_code else NA_character_
    min_ans <- if (!is.na(min_val) && safe_int(min_val) == 1) q$answer_code else NA_character_
    max_ans <- if (!is.na(max_val) && safe_int(max_val) == 1) q$answer_code else NA_character_
    
    if (!all(is.na(c(likely_ans, min_ans, max_ans)))) {
      just <- if (q$code == "IMP4.1") imp4_just else NA_character_
      dbExecute(con, "INSERT INTO answers (idAnswer, idAssessment, idQuestion, min, likely, max, justification) VALUES (?, ?, ?, ?, ?, ?, ?)",
                params = list(next_answer_id, next_assessment_id, id_question,
                              min_ans, likely_ans, max_ans, just))
      next_answer_id <- next_answer_id + 1
      answers_added <- answers_added + 1
    }
  }
  
  cat(sprintf("  Answers: %d\n", answers_added))
  
  # === PATHWAY ANSWERS (ENT2A, ENT2B, ENT3, ENT4 for each pathway) ===
  pathway_answers_added <- 0
  pathway_questions_map <- list(
    list(code = "ENT2A"),
    list(code = "ENT2B"),
    list(code = "ENT3"),
    list(code = "ENT4")
  )
  
  for (pw_num_str in names(entry_pathway_ids)) {
    pw_num <- as.integer(pw_num_str)
    id_entry_pathway <- entry_pathway_ids[[pw_num_str]]

    for (pq in pathway_questions_map) {
      id_path_question <- path_question_lookup[[pq$code]]
      if (is.null(id_path_question)) {
        cat(sprintf("  WARNING: Pathway question not found: %s\n", pq$code))
        next
      }

      # Build column names
      min_col <- sprintf("%s min PW%d", pq$code, pw_num)
      likely_col <- sprintf("%s likely PW%d", pq$code, pw_num)
      max_col <- sprintf("%s max PW%d", pq$code, pw_num)
      just_col <- sprintf("%s PW%d Justification", pq$code, pw_num)

      # Read Excel values (numeric)
      min_val <- get_col_value(row, min_col, df_cols)
      likely_val <- get_col_value(row, likely_col, df_cols)
      max_val <- get_col_value(row, max_col, df_cols)
      just_val <- get_col_value(row, just_col, df_cols)

      # Get the lookup table for this pathway question
      lookup <- pathway_lookups[[pq$code]]
      if (is.null(lookup)) {
        cat(sprintf("  WARNING: No lookup table for: %s\n", pq$code))
        next
      }

      # Convert numeric values to option codes
      min_opt <- convert_excel_to_option_code(min_val, lookup)
      likely_opt <- convert_excel_to_option_code(likely_val, lookup)
      max_opt <- convert_excel_to_option_code(max_val, lookup)

      # Insert only if at least one value exists
      if (!all(is.na(c(min_opt, likely_opt, max_opt)))) {
        dbExecute(con, "INSERT INTO pathwayAnswers (idPathAnswer, idEntryPathway, idPathQuestion, min, likely, max, justification) VALUES (?, ?, ?, ?, ?, ?, ?)",
                  params = list(next_path_answer_id, id_entry_pathway, id_path_question,
                                safe_str(min_opt), safe_str(likely_opt), safe_str(max_opt), safe_str(just_val)))
        next_path_answer_id <- next_path_answer_id + 1
        pathway_answers_added <- pathway_answers_added + 1
      }
    }
  }
  
  if (pathway_answers_added > 0) {
    cat(sprintf("  Pathway answers: %d\n", pathway_answers_added))
  }
  
  next_pest_id <- next_pest_id + 1
  next_assessment_id <- next_assessment_id + 1
}

# Summary ----------------------------------------------------------------------

cat(sprintf("Skipped assessments: %d\n", skipped_count))
cat(sprintf("Migrated assessments: %d\n\n", nrow(excel_data) - skipped_count))

cat("Final row counts:\n")
for (table in c("pests", "assessments", "assessors", "entryPathways", "answers",
                "pathwayAnswers", "threatXassessment")) {
  count <- dbGetQuery(con, sprintf("SELECT COUNT(*) as n FROM %s", table))$n
  cat(sprintf("  %s: %d rows\n", table, count))
}

dbDisconnect(con)

cat(sprintf("\nDatabase saved to: %s\n", DB_FILE))