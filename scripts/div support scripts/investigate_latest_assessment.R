library(DBI)
library(RSQLite)
library(tidyverse)

# Connect to corrupt database
corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
conn <- dbConnect(SQLite(), corrupt_db)

# Find the latest assessment
cat("=== ALL ASSESSMENTS ===\n")
assessments <- dbGetQuery(conn, "SELECT * FROM assessments ORDER BY idAssessment DESC")
print(assessments)

# Check which assessment might be the manually created one
cat("\n=== CHECKING EACH ASSESSMENT FOR COMPLETENESS ===\n")
for(i in 1:min(5, nrow(assessments))) {
  id <- assessments$idAssessment[i]
  cat("\n--- Assessment ID:", id, "---\n")
  cat("Pest ID:", assessments$idPest[i], "\n")
  cat("Assessor ID:", assessments$idAssessor[i], "\n")
  cat("Start Date:", assessments$startDate[i], "\n")
  cat("End Date:", assessments$endDate[i], "\n")
  cat("Finished:", assessments$finished[i], "\n")
  cat("Valid:", assessments$valid[i], "\n")

  # Check answers
  answers <- dbGetQuery(conn,
    sprintf("SELECT COUNT(*) as cnt FROM answers WHERE idAssessment = %d", id))
  cat("Number of answers:", answers$cnt, "\n")

  # Check entry pathways
  pathways <- dbGetQuery(conn,
    sprintf("SELECT COUNT(*) as cnt FROM entryPathways WHERE idAssessment = %d", id))
  cat("Number of entry pathways:", pathways$cnt, "\n")

  # Check pathway answers
  pa <- dbGetQuery(conn,
    sprintf("SELECT COUNT(*) as cnt FROM pathwayAnswers pa
            JOIN entryPathways ep ON pa.idEntryPathway = ep.idEntryPathway
            WHERE ep.idAssessment = %d", id))
  cat("Number of pathway answers:", pa$cnt, "\n")

  # Check if pest exists
  pest <- dbGetQuery(conn,
    sprintf("SELECT * FROM pests WHERE idPest = %d", assessments$idPest[i]))
  if(nrow(pest) > 0) {
    cat("Pest:", pest$scientificName[1], "\n")
  } else {
    cat("WARNING: Pest ID", assessments$idPest[i], "NOT FOUND IN PESTS TABLE!\n")
  }

  # Check if assessor exists
  assessor <- dbGetQuery(conn,
    sprintf("SELECT * FROM assessors WHERE idAssessor = %d", assessments$idAssessor[i]))
  if(nrow(assessor) > 0) {
    cat("Assessor:", assessor$assessorName[1], "\n")
  } else {
    cat("WARNING: Assessor ID", assessments$idAssessor[i], "NOT FOUND IN ASSESSORS TABLE!\n")
  }
}

# Check all pests
cat("\n=== ALL PESTS IN DATABASE ===\n")
pests <- dbGetQuery(conn, "SELECT * FROM pests")
print(pests)

# Check all assessors
cat("\n=== ALL ASSESSORS IN DATABASE ===\n")
assessors <- dbGetQuery(conn, "SELECT * FROM assessors")
print(assessors)

# Check questions table
cat("\n=== SAMPLE QUESTIONS ===\n")
questions <- dbGetQuery(conn, "SELECT idQuestion, questionText, groupId FROM questions LIMIT 10")
print(questions)

dbDisconnect(conn)
