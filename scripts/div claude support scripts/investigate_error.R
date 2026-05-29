library(DBI)
library(RSQLite)
library(tidyverse)

# Connect to database
db_path <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
conn <- dbConnect(SQLite(), db_path)

# List all tables
cat("=== TABLES IN DATABASE ===\n")
print(dbListTables(conn))

# Check assessments
cat("\n=== RECENT ASSESSMENTS ===\n")
assessments <- dbGetQuery(conn, "SELECT * FROM assessments ORDER BY assessmentId DESC LIMIT 5")
print(assessments)

# Check pests
cat("\n=== PESTS ===\n")
pests <- dbGetQuery(conn, "SELECT * FROM pests")
print(pests)

# Check if there are answers for the latest assessment
if(nrow(assessments) > 0) {
  latest_id <- assessments$assessmentId[1]

  cat("\n=== ANSWERS FOR LATEST ASSESSMENT (ID:", latest_id, ") ===\n")
  answers <- dbGetQuery(conn,
    sprintf("SELECT * FROM answers WHERE assessmentId = %d", latest_id))
  print(answers)

  cat("\n=== ENTRY PATHWAYS FOR LATEST ASSESSMENT ===\n")
  pathways <- dbGetQuery(conn,
    sprintf("SELECT * FROM entryPathways WHERE assessmentId = %d", latest_id))
  print(pathways)

  cat("\n=== PATHWAY ANSWERS FOR LATEST ASSESSMENT ===\n")
  pathway_answers <- dbGetQuery(conn,
    sprintf("SELECT * FROM pathwayAnswers WHERE assessmentId = %d", latest_id))
  print(pathway_answers)

  cat("\n=== THREATENED SECTORS FOR LATEST ASSESSMENT ===\n")
  threats <- dbGetQuery(conn,
    sprintf("SELECT * FROM threatXassessment WHERE assessmentId = %d", latest_id))
  print(threats)

  # Check questions table structure
  cat("\n=== QUESTIONS TABLE STRUCTURE ===\n")
  questions <- dbGetQuery(conn, "SELECT questionId, questionText, groupId FROM questions LIMIT 10")
  print(questions)

  # Check if assessment is finished/valid
  cat("\n=== ASSESSMENT STATUS ===\n")
  cat("Finished:", assessments$finished[1], "\n")
  cat("Valid:", assessments$valid[1], "\n")

  # Check simulations
  cat("\n=== SIMULATIONS FOR LATEST ASSESSMENT ===\n")
  sims <- dbGetQuery(conn,
    sprintf("SELECT * FROM simulations WHERE assessmentId = %d", latest_id))
  print(sims)

  if(nrow(sims) > 0) {
    cat("\n=== SIMULATION SUMMARIES ===\n")
    sim_summary <- dbGetQuery(conn,
      sprintf("SELECT * FROM simulationSummaries WHERE simulationId = %d", sims$simulationId[1]))
    print(sim_summary)
  }
}

dbDisconnect(conn)
