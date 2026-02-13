library(DBI)
library(RSQLite)

corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
working_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/FinnPrio_DB.db"

cat("=== WORKING DB QUESTIONS SCHEMA ===\n")
conn1 <- dbConnect(SQLite(), working_db)
schema1 <- dbGetQuery(conn1, "PRAGMA table_info(questions)")
print(schema1)

cat("\n=== WORKING DB QUESTIONS SAMPLE ===\n")
sample1 <- dbGetQuery(conn1, "SELECT * FROM questions LIMIT 3")
print(sample1)
dbDisconnect(conn1)

cat("\n=== CORRUPT DB QUESTIONS SCHEMA ===\n")
conn2 <- dbConnect(SQLite(), corrupt_db)
schema2 <- dbGetQuery(conn2, "PRAGMA table_info(questions)")
print(schema2)

cat("\n=== CORRUPT DB QUESTIONS SAMPLE ===\n")
sample2 <- dbGetQuery(conn2, "SELECT * FROM questions LIMIT 3")
print(sample2)

# Check pathway questions too
cat("\n=== CORRUPT DB PATHWAY QUESTIONS SCHEMA ===\n")
pw_schema <- dbGetQuery(conn2, "PRAGMA table_info(pathwayQuestions)")
print(pw_schema)

cat("\n=== CORRUPT DB PATHWAY QUESTIONS SAMPLE ===\n")
pw_sample <- dbGetQuery(conn2, "SELECT * FROM pathwayQuestions LIMIT 3")
print(pw_sample)

dbDisconnect(conn2)
