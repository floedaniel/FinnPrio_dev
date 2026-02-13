# scripts/migration scripts/3_add_draft_tables.R
# Migration: Add draft tables for auto-save functionality
# Run this script once per database to add the required tables

library(DBI)
library(RSQLite)

add_draft_tables <- function(db_path) {
  con <- dbConnect(RSQLite::SQLite(), db_path)
  on.exit(dbDisconnect(con))

  # Create answerDrafts table
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS answerDrafts (
      idAssessment INTEGER NOT NULL,
      idQuestion TEXT NOT NULL,
      minimum TEXT,
      likely TEXT,
      maximum TEXT,
      justification TEXT,
      savedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (idAssessment, idQuestion),
      FOREIGN KEY (idAssessment) REFERENCES assessments(idAssessment) ON DELETE CASCADE
    );
  ")

  # Create pathwayAnswerDrafts table
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS pathwayAnswerDrafts (
      idAssessment INTEGER NOT NULL,
      idPathway INTEGER NOT NULL,
      idQuestion TEXT NOT NULL,
      minimum TEXT,
      likely TEXT,
      maximum TEXT,
      justification TEXT,
      savedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (idAssessment, idPathway, idQuestion),
      FOREIGN KEY (idAssessment) REFERENCES assessments(idAssessment) ON DELETE CASCADE
    );
  ")

  message("Draft tables created successfully.")
}

# Usage: add_draft_tables("path/to/FinnPrio_DB.db")
