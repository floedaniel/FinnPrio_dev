################################################################################
# Populate assessments.notes with EPPO Datasheets
#
# This script:
# 1. Reads pests with assessments from database
# 2. Scrapes EPPO datasheet for each pest
# 3. Updates assessments.notes with the datasheet text
################################################################################

library(DBI)
library(RSQLite)
library(rvest)

# Configuration ----------------------------------------------------------------
# DB_FILE <- "./databases/selam_database_2026/selam_test_species.db"

# Set to TRUE to only update assessments where notes is NULL
ONLY_MISSING <- TRUE

# Connect to database
con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Debug: Check what's in the tables
cat("DEBUG - Pests in database:\n")
print(dbGetQuery(con, "SELECT idPest, scientificName, eppoCode FROM pests LIMIT 10"))

cat("\nDEBUG - Assessments notes lengths:\n")
print(dbGetQuery(con, "SELECT idAssessment, idPest, LENGTH(notes) as notes_len FROM assessments LIMIT 10"))

# Get assessments to process ---------------------------------------------------
cat("\nDEBUG - Checking join:\n")
join_test <- dbGetQuery(con, 
                        "SELECT a.idAssessment, a.idPest, p.idPest as pest_idPest, p.eppoCode, a.notes
   FROM assessments a
   LEFT JOIN pests p ON a.idPest = p.idPest
   LIMIT 10")
print(join_test)

if (ONLY_MISSING) {
  # Only assessments without notes (NULL, empty, or whitespace-only)
  assessments_df <- dbGetQuery(con, 
                               "SELECT a.idAssessment, p.idPest, p.scientificName, p.eppoCode 
     FROM assessments a
     JOIN pests p ON a.idPest = p.idPest
     WHERE (a.notes IS NULL OR TRIM(a.notes) = '' OR LENGTH(TRIM(a.notes)) < 100)
       AND p.eppoCode IS NOT NULL")
  cat("\nFound", nrow(assessments_df), "assessments WITHOUT notes (or notes < 100 chars)\n\n")
} else {
  # All assessments with EPPO codes
  assessments_df <- dbGetQuery(con, 
                               "SELECT a.idAssessment, p.idPest, p.scientificName, p.eppoCode 
     FROM assessments a
     JOIN pests p ON a.idPest = p.idPest
     WHERE p.eppoCode IS NOT NULL")
  cat("\nFound", nrow(assessments_df), "assessments with EPPO codes\n\n")
}

cat("DEBUG - assessments_df:\n")
print(assessments_df)

if (nrow(assessments_df) == 0) {
  cat("Nothing to process.\n")
  dbDisconnect(con)
  stop("No assessments to process")
}

# Function to scrape datasheet -------------------------------------------------
scrape_datasheet <- function(eppocode) {
  url <- paste0("https://gd.eppo.int/taxon/", eppocode, "/datasheet")
  
  tryCatch({
    datasheet <- url %>%
      read_html(encoding = "UTF-8") %>%
      html_nodes(".datasheet") %>%
      html_text()
    
    if (length(datasheet) > 0 && nchar(datasheet[1]) > 0) {
      return(datasheet[1])
    } else {
      return(NA_character_)
    }
  }, error = function(e) {
    cat("    Error:", e$message, "\n")
    return(NA_character_)
  })
}

# Process each assessment ------------------------------------------------------
updated_count <- 0

for (i in seq_len(nrow(assessments_df))) {
  assessment <- assessments_df[i, ]
  eppocode <- assessment$eppoCode
  
  cat("[", i, "/", nrow(assessments_df), "] ", assessment$scientificName, " (", eppocode, ")\n", sep = "")
  
  # Scrape datasheet
  datasheet_text <- scrape_datasheet(eppocode)
  
  if (!is.na(datasheet_text) && nchar(datasheet_text) > 0) {
    # Update assessment notes
    rows_affected <- dbExecute(con,
                               "UPDATE assessments SET notes = ? WHERE idAssessment = ?",
                               params = list(datasheet_text, assessment$idAssessment)
    )
    cat("  Updated notes (", nchar(datasheet_text), " chars) - rows affected: ", rows_affected, "\n", sep = "")
    updated_count <- updated_count + 1
    
    # Verify update
    verify <- dbGetQuery(con, "SELECT notes FROM assessments WHERE idAssessment = ?", 
                         params = list(assessment$idAssessment))
    cat("  Verify: notes length = ", nchar(verify$notes[1]), "\n", sep = "")
  } else {
    cat("  No datasheet found\n")
  }
  
  # Small delay to be polite to EPPO server
  Sys.sleep(0.5)
}

# Summary ----------------------------------------------------------------------
cat("\n================================================================================\n")
cat("DONE!\n")
cat("================================================================================\n\n")

cat("Updated", updated_count, "assessments with EPPO datasheets\n\n")

cat("Assessments summary:\n")
summary_df <- dbGetQuery(con, 
                         "SELECT a.idAssessment, p.scientificName, p.eppoCode,
          CASE WHEN a.notes IS NOT NULL AND a.notes != '' THEN 'Yes' ELSE 'No' END as hasNotes
   FROM assessments a 
   JOIN pests p ON a.idPest = p.idPest
   ORDER BY a.idAssessment
   LIMIT 20")

print(summary_df)

dbDisconnect(con)