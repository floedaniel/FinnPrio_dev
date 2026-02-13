################################################################################
# Clear Database Script - Safe Version
#
# This script deletes all data from assessment-related tables while keeping
# the table structure and reference data intact
#
# WARNING: This will permanently delete assessment data!
# Make sure to backup your database before running this script!
################################################################################

library(DBI)
library(RSQLite)

# Configuration
DB_FILE <- "./clean database/FinnPrio_DB.db"

con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Connect to database
cat("Connecting to database:", DB_FILE, "\n")
con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# Check which tables exist
all_tables <- dbListTables(con)
cat("\nTables in database:\n")
print(all_tables)
cat("\n")

# Define tables to clear (assessment data only)
tables_to_clear <- c(
  "simulationSummaries",
  "simulations",
  "pathwayAnswers",
  "answers",
  "threatXassessment",
  "entryPathways",
  "assessments",
  "pests"
)

# Filter to only existing tables
tables_to_clear <- tables_to_clear[tables_to_clear %in% all_tables]

cat("Tables to be cleared:\n")
print(tables_to_clear)
cat("\n")

# Disable foreign key constraints
cat("Disabling foreign key constraints...\n")
dbExecute(con, "PRAGMA foreign_keys = OFF")

# Delete data from each table
cat("\nDeleting data...\n")

for (table in tables_to_clear) {
  tryCatch({
    cat(sprintf("  Clearing %s...", table))

    # Check row count before
    count_before <- dbGetQuery(con, sprintf("SELECT COUNT(*) as n FROM %s", table))$n

    # Delete all rows
    dbExecute(con, sprintf("DELETE FROM %s", table))

    # Check row count after
    count_after <- dbGetQuery(con, sprintf("SELECT COUNT(*) as n FROM %s", table))$n

    cat(sprintf(" deleted %d rows\n", count_before - count_after))

  }, error = function(e) {
    cat(sprintf(" ERROR: %s\n", e$message))
  })
}

# Reset autoincrement sequences
cat("\nResetting autoincrement counters...\n")

tryCatch({
  dbExecute(con, "DELETE FROM sqlite_sequence WHERE name IN ('pests', 'assessments', 'answers', 'pathwayAnswers', 'entryPathways', 'threatXassessment', 'simulations', 'simulationSummaries')")
  cat("  Counters reset\n")
}, error = function(e) {
  cat(sprintf("  Warning: Could not reset counters: %s\n", e$message))
})

# Re-enable foreign key constraints
cat("\nRe-enabling foreign key constraints...\n")
dbExecute(con, "PRAGMA foreign_keys = ON")


for (table in tables_to_clear) {
  tryCatch({
    count <- dbGetQuery(con, sprintf("SELECT COUNT(*) as n FROM %s", table))$n
    cat(sprintf("  %-30s : %d rows\n", table, count))
  }, error = function(e) {
    cat(sprintf("  %-30s : ERROR\n", table))
  })
}

cat("\n")

# Check reference tables
reference_tables <- c("assessors", "pathways", "pathwayQuestions",
                      "quarantineStatus", "questions", "taxonomicGroups",
                      "threatenedSectors")

# Filter to existing tables
reference_tables <- reference_tables[reference_tables %in% all_tables]

if (length(reference_tables) > 0) {
  cat("Reference tables (should still have data):\n")
  for (table in reference_tables) {
    tryCatch({
      count <- dbGetQuery(con, sprintf("SELECT COUNT(*) as n FROM %s", table))$n
      cat(sprintf("  %-30s : %d rows\n", table, count))
    }, error = function(e) {
      cat(sprintf("  %-30s : ERROR\n", table))
    })
  }
}

# Close connection
dbDisconnect(con)


