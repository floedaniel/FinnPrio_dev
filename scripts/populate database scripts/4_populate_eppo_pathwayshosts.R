################################################################################
# Populate assessments.potentialEntryPathways from EPPO Website
#
# This script:
# 1. Reads pests with assessments from database
# 2. Scrapes pathway hosts table from EPPO website
# 3. Updates assessments.potentialEntryPathways with formatted text
################################################################################

library(DBI)
library(RSQLite)
library(rvest)
library(tidyverse)

# Configuration ----------------------------------------------------------------
#DB_FILE <- "./databases/selam_database_2026/selam_test_species.db"

# Set to TRUE to only update assessments where potentialEntryPathways is NULL/empty
ONLY_MISSING <- TRUE

# Connect to database
con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Get assessments to process ---------------------------------------------------
if (ONLY_MISSING) {
  assessments_df <- dbGetQuery(con, 
                               "SELECT a.idAssessment, p.idPest, p.scientificName, p.eppoCode 
     FROM assessments a
     JOIN pests p ON a.idPest = p.idPest
     WHERE (a.potentialEntryPathways IS NULL OR TRIM(a.potentialEntryPathways) = '')
       AND p.eppoCode IS NOT NULL")
  cat("Found", nrow(assessments_df), "assessments WITHOUT potentialEntryPathways\n\n")
} else {
  assessments_df <- dbGetQuery(con, 
                               "SELECT a.idAssessment, p.idPest, p.scientificName, p.eppoCode 
     FROM assessments a
     JOIN pests p ON a.idPest = p.idPest
     WHERE p.eppoCode IS NOT NULL")
  cat("Found", nrow(assessments_df), "assessments with EPPO codes\n\n")
}

if (nrow(assessments_df) == 0) {
  cat("Nothing to process.\n")
  dbDisconnect(con)
  stop("No assessments to process")
}

# Function to scrape pathways from EPPO website --------------------------------
scrape_pathways <- function(eppocode) {
  url <- paste0("https://gd.eppo.int/taxon/", eppocode, "/pathwayshosts")
  
  tryCatch({
    page <- read_html(url)
    tables <- page %>% html_nodes("table")
    
    if (length(tables) == 0) return(NULL)
    
    # Parse table
    tbl <- tables[[1]] %>% html_table(fill = TRUE)
    
    if (nrow(tbl) == 0 || ncol(tbl) < 2) return(NULL)
    
    # Rename columns
    names(tbl) <- c("Type", "Host")
    
    # Clean: get unique Types and Hosts
    types <- unique(trimws(tbl$Type))
    types <- types[types != "" & !is.na(types)]
    
    hosts <- unique(trimws(tbl$Host))
    hosts <- hosts[hosts != "" & !is.na(hosts)]
    
    # Format: "Type: x, y, z. Host: a, b, c"
    result <- ""
    if (length(types) > 0) {
      result <- paste0("Type: ", paste(types, collapse = ", "))
    }
    if (length(hosts) > 0) {
      if (nchar(result) > 0) result <- paste0(result, ". ")
      result <- paste0(result, "Host: ", paste(hosts, collapse = ", "))
    }
    
    return(list(text = result, n_types = length(types), n_hosts = length(hosts)))
    
  }, error = function(e) {
    return(NULL)
  })
}

# Process each assessment ------------------------------------------------------
updated_count <- 0

for (i in seq_len(nrow(assessments_df))) {
  assessment <- assessments_df[i, ]
  eppocode <- assessment$eppoCode
  
  cat("[", i, "/", nrow(assessments_df), "] ", assessment$scientificName, " (", eppocode, ")\n", sep = "")
  
  result <- scrape_pathways(eppocode)
  
  if (!is.null(result) && nchar(result$text) > 0) {
    dbExecute(con,
              "UPDATE assessments SET potentialEntryPathways = ? WHERE idAssessment = ?",
              params = list(result$text, assessment$idAssessment)
    )
    
    cat("  Types:", result$n_types, "| Hosts:", result$n_hosts, "\n")
    updated_count <- updated_count + 1
  } else {
    cat("  No pathways found\n")
  }
  
  # Small delay to be polite to EPPO server
  Sys.sleep(0.5)
}

# Summary ----------------------------------------------------------------------
cat("\n================================================================================\n")
cat("DONE!\n")
cat("================================================================================\n\n")

cat("Updated", updated_count, "assessments with pathway data\n\n")

cat("Sample of potentialEntryPathways:\n")
sample_df <- dbGetQuery(con, 
                        "SELECT a.idAssessment, p.scientificName, a.potentialEntryPathways
   FROM assessments a
   JOIN pests p ON a.idPest = p.idPest
   WHERE a.potentialEntryPathways IS NOT NULL
   LIMIT 5")
print(sample_df)

dbDisconnect(con)