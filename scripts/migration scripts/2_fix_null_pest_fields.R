################################################################################
# Fix NULL values in pests table for idTaxa, idQuarantineStatus, and inEurope
#
# This script updates existing pests that have NULL values in required fields
# to prevent app crashes when loading assessments.
################################################################################

library(DBI)
library(RSQLite)

# Configuration ----------------------------------------------------------------
DB_FILE <- "./selam/selam_2026.db"

# Default values (same as script 5)
DEFAULT_ID_TAXA <- 1L              # Insects
DEFAULT_ID_QUARANTINE <- 4L        # Other quarantine
DEFAULT_IN_EUROPE <- 0L            # FALSE

# Connect to database
con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Check current state ----------------------------------------------------------
cat("Checking for NULL values in pests table...\n\n")

null_counts <- dbGetQuery(con,
  "SELECT
    COUNT(*) as total_pests,
    SUM(CASE WHEN idTaxa IS NULL THEN 1 ELSE 0 END) as null_taxa,
    SUM(CASE WHEN idQuarantineStatus IS NULL THEN 1 ELSE 0 END) as null_quaran,
    SUM(CASE WHEN inEurope IS NULL THEN 1 ELSE 0 END) as null_inEurope
   FROM pests")

print(null_counts)
cat("\n")

if (null_counts$null_taxa == 0 && null_counts$null_quaran == 0 && null_counts$null_inEurope == 0) {
  cat("No NULL values found. Nothing to fix!\n")
  dbDisconnect(con)
  quit(save = "no")
}

# Get pests with NULL values ---------------------------------------------------
pests_to_fix <- dbGetQuery(con,
  "SELECT idPest, scientificName, eppoCode, idTaxa, idQuarantineStatus, inEurope
   FROM pests
   WHERE idTaxa IS NULL OR idQuarantineStatus IS NULL OR inEurope IS NULL")

cat("Found", nrow(pests_to_fix), "pests with NULL values:\n")
print(pests_to_fix)
cat("\n")

# Confirm before updating ------------------------------------------------------
cat("This will update these pests with default values:\n")
cat("  - idTaxa = ", DEFAULT_ID_TAXA, " (Insects)\n", sep = "")
cat("  - idQuarantineStatus = ", DEFAULT_ID_QUARANTINE, " (Other quarantine)\n", sep = "")
cat("  - inEurope = ", DEFAULT_IN_EUROPE, " (FALSE)\n\n", sep = "")

response <- readline(prompt = "Proceed with update? (yes/no): ")

if (tolower(trimws(response)) != "yes") {
  cat("Update cancelled.\n")
  dbDisconnect(con)
  quit(save = "no")
}

# Update NULL values -----------------------------------------------------------
cat("\nUpdating pests...\n")

# Update idTaxa
rows_taxa <- dbExecute(con,
  "UPDATE pests SET idTaxa = ? WHERE idTaxa IS NULL",
  params = list(DEFAULT_ID_TAXA))
cat("  Updated", rows_taxa, "pests with idTaxa\n")

# Update idQuarantineStatus
rows_quaran <- dbExecute(con,
  "UPDATE pests SET idQuarantineStatus = ? WHERE idQuarantineStatus IS NULL",
  params = list(DEFAULT_ID_QUARANTINE))
cat("  Updated", rows_quaran, "pests with idQuarantineStatus\n")

# Update inEurope
rows_europe <- dbExecute(con,
  "UPDATE pests SET inEurope = ? WHERE inEurope IS NULL",
  params = list(DEFAULT_IN_EUROPE))
cat("  Updated", rows_europe, "pests with inEurope\n")

# Verify -----------------------------------------------------------------------
cat("\nVerifying updates...\n")

after_counts <- dbGetQuery(con,
  "SELECT
    COUNT(*) as total_pests,
    SUM(CASE WHEN idTaxa IS NULL THEN 1 ELSE 0 END) as null_taxa,
    SUM(CASE WHEN idQuarantineStatus IS NULL THEN 1 ELSE 0 END) as null_quaran,
    SUM(CASE WHEN inEurope IS NULL THEN 1 ELSE 0 END) as null_inEurope
   FROM pests")

print(after_counts)
cat("\n")

if (after_counts$null_taxa == 0 && after_counts$null_quaran == 0 && after_counts$null_inEurope == 0) {
  cat("SUCCESS! All NULL values have been fixed.\n\n")
} else {
  cat("WARNING: Some NULL values remain. Check manually.\n\n")
}

cat("Updated pests:\n")
updated_pests <- dbGetQuery(con,
  "SELECT idPest, scientificName, eppoCode, idTaxa, idQuarantineStatus, inEurope
   FROM pests
   WHERE idPest IN (", paste(pests_to_fix$idPest, collapse = ", "), ")")
print(updated_pests)

cat("\n")
cat("IMPORTANT: Please update these values manually in the app for accuracy!\n")

dbDisconnect(con)
