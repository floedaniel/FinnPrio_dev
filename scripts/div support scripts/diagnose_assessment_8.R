library(DBI)
library(RSQLite)
library(tidyverse)

corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
conn <- dbConnect(SQLite(), corrupt_db)

# Get all questions
cat("=== ALL MAIN QUESTIONS (should have ~20) ===\n")
questions <- dbGetQuery(conn, "SELECT idQuestion, questionText, groupId FROM questions ORDER BY idQuestion")
cat("Total questions:", nrow(questions), "\n")
print(questions)

# Get answers for assessment 8
cat("\n=== ANSWERS FOR ASSESSMENT 8 ===\n")
answers <- dbGetQuery(conn, "SELECT * FROM answers WHERE idAssessment = 8")
cat("Total answers:", nrow(answers), "\n")
print(answers)

# Find missing question answers
cat("\n=== MISSING QUESTIONS FOR ASSESSMENT 8 ===\n")
answered_questions <- answers$idQuestion
missing <- questions %>%
  filter(!idQuestion %in% answered_questions)
cat("Missing", nrow(missing), "questions:\n")
print(missing$questionText)

# Check pathway questions
cat("\n=== PATHWAY QUESTIONS ===\n")
pathway_questions <- dbGetQuery(conn, "SELECT * FROM pathwayQuestions ORDER BY idPathQuestion")
cat("Total pathway questions:", nrow(pathway_questions), "\n")
print(pathway_questions %>% select(idPathQuestion, questionText, idPathway))

# Check entry pathways for assessment 8
cat("\n=== ENTRY PATHWAYS FOR ASSESSMENT 8 ===\n")
entry_pathways <- dbGetQuery(conn, "SELECT * FROM entryPathways WHERE idAssessment = 8")
print(entry_pathways)

# Check pathway answers
cat("\n=== PATHWAY ANSWERS FOR ASSESSMENT 8 ===\n")
pathway_answers <- dbGetQuery(conn, "
  SELECT pa.*, ep.idPathway, pq.questionText
  FROM pathwayAnswers pa
  JOIN entryPathways ep ON pa.idEntryPathway = ep.idEntryPathway
  JOIN pathwayQuestions pq ON pa.idPathQuestion = pq.idPathQuestion
  WHERE ep.idAssessment = 8
")
cat("Total pathway answers:", nrow(pathway_answers), "\n")
print(pathway_answers)

# Check if pathway 2 has questions
if(nrow(entry_pathways) > 0) {
  pathway_id <- entry_pathways$idPathway[1]
  cat("\n=== REQUIRED PATHWAY QUESTIONS FOR PATHWAY", pathway_id, "===\n")
  required_pw_questions <- dbGetQuery(conn,
    sprintf("SELECT * FROM pathwayQuestions WHERE idPathway = %d OR idPathway IS NULL", pathway_id))
  cat("Total required pathway questions:", nrow(required_pw_questions), "\n")
  print(required_pw_questions %>% select(idPathQuestion, questionText, idPathway))
}

dbDisconnect(conn)
