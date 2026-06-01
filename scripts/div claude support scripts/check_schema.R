library(DBI)
library(RSQLite)

# Connect to database
db_path <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
conn <- dbConnect(SQLite(), db_path)

# Check assessments table schema
cat("=== ASSESSMENTS TABLE SCHEMA ===\n")
schema <- dbGetQuery(conn, "PRAGMA table_info(assessments)")
print(schema)

# Try to view assessments without assuming column name
cat("\n=== ALL DATA FROM ASSESSMENTS TABLE ===\n")
assessments <- dbGetQuery(conn, "SELECT * FROM assessments")
print(assessments)
cat("Number of rows:", nrow(assessments), "\n")

# Check answers table schema
cat("\n=== ANSWERS TABLE SCHEMA ===\n")
answers_schema <- dbGetQuery(conn, "PRAGMA table_info(answers)")
print(answers_schema)

# Check if there are any answers
cat("\n=== ANSWERS TABLE DATA ===\n")
answers <- dbGetQuery(conn, "SELECT * FROM answers LIMIT 10")
print(answers)

# Check entryPathways schema
cat("\n=== ENTRYPATHWAYS TABLE SCHEMA ===\n")
pathways_schema <- dbGetQuery(conn, "PRAGMA table_info(entryPathways)")
print(pathways_schema)

# Check pests
cat("\n=== PESTS TABLE ===\n")
pests <- dbGetQuery(conn, "SELECT * FROM pests")
print(pests)

# Check assessors
cat("\n=== ASSESSORS TABLE ===\n")
assessors <- dbGetQuery(conn, "SELECT * FROM assessors")
print(assessors)

dbDisconnect(conn)
