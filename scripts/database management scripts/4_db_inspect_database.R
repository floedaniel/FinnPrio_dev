
library(DBI)
library(RSQLite)
library(tidyverse)

# Configuration
DB_FILE <- "./databases/daniel_database_2026/demo.db"

con <- dbConnect(RSQLite::SQLite(), DB_FILE)

# List all tables
dbListTables(con)

# pests
pests_df <- dbReadTable(con, "pests")

as_tibble(pests_df)

# assessments
assessments_df <- dbReadTable(con, "assessments")

as_tibble(assessments_df)

glimpse(assessments_df)

assessments_df$notes

# questions 

questions_df <- dbReadTable(con, "questions")

as_tibble(questions_df)
glimpse(questions_df)

# questions 

answers_df <- dbReadTable(con, "answers")

as_tibble(answers_df)
glimpse(answers_df)


#  Assessors

assessors_df <- dbReadTable(con, "Assessors")

as_tibble(assessors_df)
glimpse(answers_df)

# dbDisconnect(con)


# full --------------------------------------------------------------------


tables <- dbListTables(con)

for (tbl in tables) {
  cat("\n============================\n")
  cat("table:", tbl, "\n")
  cat("============================\n")
  
  df <- dbReadTable(con, tbl)
  tb <- as_tibble(df)
  
  print(tb)
  
  cat("\ncolumn structure:\n")
  print(glimpse(tb))
}

dbDisconnect(con)


# -------------------------------------------------------------------------

dbGetQuery(con, "SELECT * FROM answers LIMIT 10")
dbGetQuery(con, "SELECT * FROM questions WHERE idQuestion = 1")
dbGetQuery(con, "PRAGMA foreign_key_list(answers)")
dbGetQuery(con, "SELECT COUNT(*) as n, idQuestion FROM answers GROUP BY idQuestion")



# -------------------------------------------------------------------------

dbGetQuery(con, "SELECT idAssessment, idQuestion, COUNT(*) as n FROM answers GROUP BY idAssessment, idQuestion HAVING n > 1")
dbGetQuery(con, "SELECT a.idAssessment FROM answers a LEFT JOIN assessments ass ON a.idAssessment = ass.idAssessment WHERE ass.idAssessment IS NULL")
dbGetQuery(con, "SELECT idAnswer, min, typeof(min) FROM answers LIMIT 5")


# How many questions are there?
dbGetQuery(con, "SELECT COUNT(*) FROM questions")

# Does any working assessment have all questions answered?
dbGetQuery(con, "SELECT idAssessment, COUNT(*) as n_answers FROM answers GROUP BY idAssessment ORDER BY n_answers DESC LIMIT 5")


# Add empty answers for questions 2-18 for assessment 1
for (q in 2:18) {
  dbExecute(con, 
            "INSERT INTO answers (idAssessment, idQuestion, min, likely, max, justification) 
     VALUES (?, ?, ?, ?, ?, ?)",
            params = list(1L, q, NA, NA, NA, NA)
  )
}

# Check
dbGetQuery(con, "SELECT idAssessment, COUNT(*) as n_answers FROM answers WHERE idAssessment = 1")


# What does the app expect? Maybe min/likely/max need default values, not NULL?
# Let's try setting empty strings instead of NULL for assessment 1
dbExecute(con, "UPDATE answers SET min = '', likely = '', max = '' WHERE idAssessment = 1")

# Check result
dbGetQuery(con, "SELECT * FROM answers WHERE idAssessment = 1 LIMIT 3")

