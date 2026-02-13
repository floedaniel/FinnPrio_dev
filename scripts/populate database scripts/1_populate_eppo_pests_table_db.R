################################################################################
# EPPO API to FinnPrio Database Population Script
################################################################################

library(DBI)
library(RSQLite)
library(httr2)
library(jsonlite)
library(tidyverse)
library(rgbif)

# -------------------------------------------------------------------------

DB_FILE <- "./databases/sandra_database_2026/sandra.db"

# INPUT - Your EPPO codes here -------------------------------------------------
# Sys.setlocale("LC_ALL", "en_US.UTF-8")
master_species <- rio::import("C:/Users/dafl/Downloads/master_species.xlsx") %>% as_tibble()

# master_df <- master_species %>% filter(is.na(Batch))

master_species %>% distinct(assessor)

master_df <- master_species %>% filter(assessor=="Sandra A. I. Wright")

master_df <- master_df %>% filter(!status=="completed")
master_df <- master_df %>% filter(!status=="already regulated")
master_df

input <- master_df$eppocode

input

# OPTIONAL: Add assessor to database -----------------------------------------------
# Set ADD_ASSESSOR to TRUE if you want to add/check an assessor
ADD_ASSESSOR <- TRUE

assessor_first_name <- "Sandra"
assessor_last_name  <- "Wright"
assessor_email      <- "sandra.wright@hig.se" #NA_character_  # Optional, can be NA

# Connect to database
con <- dbConnect(RSQLite::SQLite(), DB_FILE)


if (ADD_ASSESSOR) {
  # Check if assessor already exists
  existing <- dbGetQuery(con,
                         "SELECT * FROM assessors WHERE firstName = ? AND lastName = ?",
                         params = list(assessor_first_name, assessor_last_name))
  
  if (nrow(existing) > 0) {
    cat("Assessor already exists: ", assessor_first_name, " ", assessor_last_name,
        " (ID: ", existing$idAssessor, ")\n\n", sep = "")
  } else {
    # Get next assessor ID
    max_assessor_id <- dbGetQuery(con, "SELECT MAX(idAssessor) as max_id FROM assessors")$max_id
    next_assessor_id <- if (is.na(max_assessor_id)) 1 else max_assessor_id + 1
    
    # Insert new assessor
    dbExecute(con,
              "INSERT INTO assessors (idAssessor, firstName, lastName, email) VALUES (?, ?, ?, ?)",
              params = list(next_assessor_id, assessor_first_name, assessor_last_name, assessor_email))
    
    cat("Added assessor: ", assessor_first_name, " ", assessor_last_name,
        " (ID: ", next_assessor_id, ")\n\n", sep = "")
  }
  
  cat("Current assessors:\n")
  print(dbGetQuery(con, "SELECT * FROM assessors"))
  cat("\n")
}

# Configuration ----------------------------------------------------------------
API_KEY_FILE <- "C:/Users/dafl/Desktop/API keys/EPPO_beta.txt"

api_key <- readLines(API_KEY_FILE, warn = FALSE)[1]


# Get starting ID
max_id <- dbGetQuery(con, "SELECT MAX(idPest) as max_id FROM pests")$max_id
next_id <- if (is.na(max_id)) 1 else max_id + 1

cat("Processing", length(input), "EPPO codes\n")
cat("Starting pest ID:", next_id, "\n\n")

# Loop through EPPO codes ------------------------------------------------------
for (eppocode in input) {
  
  cat("[", eppocode, "]\n", sep = "")
  
  # Check if already exists
  exists_check <- dbGetQuery(con, "SELECT COUNT(*) as n FROM pests WHERE eppoCode = ?",
                             params = list(eppocode))
  if (exists_check$n > 0) {
    cat("  Skipped - already exists\n")
    next
  }
  
  # Get overview data
  url_overview <- paste0("https://api.eppo.int/gd/v2/taxons/taxon/", eppocode, "/overview")
  resp_overview <- tryCatch({
    request(url_overview) |>
      req_headers("X-Api-Key" = api_key, "Accept" = "application/json") |>
      req_perform()
  }, error = function(e) NULL)
  
  if (is.null(resp_overview)) {
    cat("  FAILED - could not fetch overview\n")
    next
  }
  
  overview <- resp_body_json(resp_overview)
  scientific_name <- overview$prefname
  
  # Get names data
  url_names <- paste0("https://api.eppo.int/gd/v2/taxons/taxon/", eppocode, "/names")
  resp_names <- tryCatch({
    request(url_names) |>
      req_headers("X-Api-Key" = api_key, "Accept" = "application/json") |>
      req_perform()
  }, error = function(e) NULL)
  
  names_data <- if (!is.null(resp_names)) resp_body_json(resp_names) else list()
  
  # Extract synonyms (Latin, not preferred)
  synonyms_list <- c()
  for (entry in names_data) {
    is_latin <- !is.null(entry$lang_iso) && entry$lang_iso == "la"
    is_not_preferred <- !isTRUE(entry$preferred)
    if (is_latin && is_not_preferred) {
      synonyms_list <- c(synonyms_list, entry$fullname)
    }
  }
  synonyms <- if (length(synonyms_list) > 0) paste(synonyms_list, collapse = ", ") else NA_character_
  
  # Extract common names (English)
  common_names_list <- c()
  for (entry in names_data) {
    is_english <- !is.null(entry$lang_iso) && entry$lang_iso == "en"
    if (is_english) {
      common_names_list <- c(common_names_list, entry$fullname)
    }
  }
  vernacular_name <- if (length(common_names_list) > 0) paste(common_names_list, collapse = ", ") else NA_character_
  
  # Get GBIF taxon key
  gbif_result <- tryCatch({
    rgbif::name_backbone(name = scientific_name)
  }, error = function(e) list())
  gbif_key <- if (!is.null(gbif_result$usageKey)) as.character(gbif_result$usageKey) else NA_character_

  # Set default values for required fields (must be updated manually in app)
  #
  # idTaxa options (from taxonomicGroups table):
  #   1 = Insects [1INSEC]
  #   2 = Mites [1ACARO]
  #   3 = Nematodes [1NEMAP]
  #   4 = Snails and slugs (Molluscs) [1MOLLP]
  #   5 = Bacteria and phytoplasma [1BACTK]
  #   6 = Fungi and fungus-like organisms [1FUNGK or 1PSDFP]
  #   7 = Viruses and viroids [1VIRUK]
  #   8 = Invasive alien plants [1MAGP]
  #
  # idQuarantineStatus options (from quarantineStatus table):
  #   1 = Priority
  #   2 = Protected zone
  #   3 = Emergency measures
  #   4 = Other quarantine
  #   5 = RNQP
  #   6 = Other non-quarantine
  #
  # inEurope options:
  #   0 = FALSE (not present in Europe)
  #   1 = TRUE (present in Europe)
  #
  id_taxa <- 1L              # Default: Insects (UPDATE MANUALLY)
  id_quarantine <- 6L        # Default: Other quarantine (UPDATE MANUALLY)
  in_europe <- 0L            # Default: FALSE (UPDATE MANUALLY)

  # Insert into database with ALL required fields
  dbExecute(con,
            "INSERT INTO pests (idPest, scientificName, eppoCode, synonyms, vernacularName, gbifTaxonKey, idTaxa, idQuarantineStatus, inEurope)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params = list(next_id, scientific_name, eppocode, synonyms, vernacular_name, gbif_key, id_taxa, id_quarantine, in_europe)
  )
  
  cat("  Added:", scientific_name, "(ID:", next_id, ")\n")
  cat("  Vernacular:", vernacular_name %||% "N/A", "\n")
  cat("  GBIF key:", gbif_key %||% "N/A", "\n")
  cat("  NOTE: Taxonomy, Quarantine Status, and inEurope set to defaults - UPDATE IN APP\n")
  
  next_id <- next_id + 1
}

# Summary ----------------------------------------------------------------------
cat("\n================================================================================\n")
cat("DONE!\n")
cat("================================================================================\n\n")

cat("Added", length(input), "pests to database\n\n")

cat("IMPORTANT: Default values were set for:\n")
cat("  - idTaxa = 1 (Insects)\n")
cat("  - idQuarantineStatus = 4 (Other quarantine)\n")
cat("  - inEurope = 0 (FALSE)\n\n")
cat("Please UPDATE these values manually in the app for each pest!\n\n")

cat("Final pests table:\n")
print(dbGetQuery(con, "SELECT idPest, scientificName, eppoCode, idTaxa, idQuarantineStatus, inEurope FROM pests"))

dbDisconnect(con)

