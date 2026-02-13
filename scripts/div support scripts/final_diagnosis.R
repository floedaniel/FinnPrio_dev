library(DBI)
library(RSQLite)

corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
conn <- dbConnect(SQLite(), corrupt_db)

# Get all questions
cat("=== TOTAL QUESTIONS IN DATABASE ===\n")
questions <- dbGetQuery(conn, "SELECT COUNT(*) as cnt FROM questions")
cat("Total questions:", questions$cnt, "\n")

# Get answers for assessment 8
cat("\n=== ANSWERS FOR ASSESSMENT 8 ===\n")
answers <- dbGetQuery(conn, "SELECT * FROM answers WHERE idAssessment = 8")
cat("Total answers for assessment 8:", nrow(answers), "\n")
print(answers)

# Get all main questions with their IDs
cat("\n=== ALL MAIN QUESTIONS ===\n")
all_questions <- dbGetQuery(conn, "SELECT idQuestion, group, number FROM questions ORDER BY idQuestion")
print(all_questions)

# Find which questions are answered
cat("\n=== WHICH QUESTIONS ARE ANSWERED FOR ASSESSMENT 8? ===\n")
if(nrow(answers) > 0) {
  answered <- all_questions[all_questions$idQuestion %in% answers$idQuestion, ]
  cat("Answered questions:\n")
  print(answered)

  cat("\n=== WHICH QUESTIONS ARE MISSING FOR ASSESSMENT 8? ===\n")
  missing <- all_questions[!all_questions$idQuestion %in% answers$idQuestion, ]
  cat("Missing", nrow(missing), "questions:\n")
  print(missing)
}

# Check entry pathways
cat("\n=== ENTRY PATHWAYS FOR ASSESSMENT 8 ===\n")
entry_pathways <- dbGetQuery(conn, "SELECT * FROM entryPathways WHERE idAssessment = 8")
print(entry_pathways)

if(nrow(entry_pathways) > 0) {
  # Check what pathway questions should be answered
  pathway_id <- entry_pathways$idPathway[1]
  cat("\n=== PATHWAY QUESTIONS FOR PATHWAY", pathway_id, "===\n")
  pw_questions <- dbGetQuery(conn,
    "SELECT idPathQuestion, group, number, idPathway FROM pathwayQuestions
     WHERE idPathway IS NULL OR idPathway = ?",
    params = list(pathway_id))
  cat("Total pathway questions needed:", nrow(pw_questions), "\n")
  print(pw_questions)

  # Check pathway answers
  cat("\n=== PATHWAY ANSWERS FOR ASSESSMENT 8 ===\n")
  pw_answers <- dbGetQuery(conn,
    "SELECT * FROM pathwayAnswers WHERE idEntryPathway = ?",
    params = list(entry_pathways$idEntryPathway[1]))
  cat("Total pathway answers:", nrow(pw_answers), "\n")
  print(pw_answers)

  if(nrow(pw_answers) == 0) {
    cat("\nWARNING: NO PATHWAY ANSWERS! This will cause simulation errors.\n")
  }
}

# Check the specific answer that exists
if(nrow(answers) > 0) {
  cat("\n=== DETAILS OF THE ONE ANSWER THAT EXISTS ===\n")
  question_id <- answers$idQuestion[1]
  question_details <- dbGetQuery(conn,
    "SELECT * FROM questions WHERE idQuestion = ?",
    params = list(question_id))
  cat("Question:", question_details$question, "\n")
  cat("Group:", question_details$group, "\n")
  cat("Answer min:", answers$min, "\n")
  cat("Answer likely:", answers$likely, "\n")
  cat("Answer max:", answers$max, "\n")
}

dbDisconnect(conn)
