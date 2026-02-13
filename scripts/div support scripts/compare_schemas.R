library(DBI)
library(RSQLite)

# Compare schemas between working and corrupt database
working_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/FinnPrio_DB.db"
corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"

cat("=== WORKING DATABASE SCHEMA ===\n")
conn1 <- dbConnect(SQLite(), working_db)
schema1 <- dbGetQuery(conn1, "PRAGMA table_info(assessments)")
print(schema1)
dbDisconnect(conn1)

cat("\n=== CORRUPT DATABASE SCHEMA ===\n")
conn2 <- dbConnect(SQLite(), corrupt_db)
schema2 <- dbGetQuery(conn2, "PRAGMA table_info(assessments)")
print(schema2)

cat("\n=== ANSWERS TABLE SCHEMA IN CORRUPT DB ===\n")
answers_schema <- dbGetQuery(conn2, "PRAGMA table_info(answers)")
print(answers_schema)

cat("\n=== ENTRYPATHWAYS TABLE SCHEMA IN CORRUPT DB ===\n")
pathways_schema <- dbGetQuery(conn2, "PRAGMA table_info(entryPathways)")
print(pathways_schema)

cat("\n=== PATHWAYANSWERS TABLE SCHEMA IN CORRUPT DB ===\n")
pa_schema <- dbGetQuery(conn2, "PRAGMA table_info(pathwayAnswers)")
print(pa_schema)

dbDisconnect(conn2)

cat("\n=== WORKING DATABASE ANSWERS SCHEMA ===\n")
conn1 <- dbConnect(SQLite(), working_db)
ans_schema1 <- dbGetQuery(conn1, "PRAGMA table_info(answers)")
print(ans_schema1)
dbDisconnect(conn1)
