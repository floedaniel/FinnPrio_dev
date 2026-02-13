library(DBI)
library(RSQLite)

corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"
conn <- dbConnect(SQLite(), corrupt_db)

# Check assessor 1
cat("=== ASSESSOR 1 ===\n")
assessor <- dbGetQuery(conn, "SELECT * FROM assessors WHERE idAssessor = 1")
print(assessor)

# Check schema
cat("\n=== ASSESSORS TABLE SCHEMA ===\n")
schema <- dbGetQuery(conn, "PRAGMA table_info(assessors)")
print(schema)

# Check all assessors
cat("\n=== ALL ASSESSORS ===\n")
all_assessors <- dbGetQuery(conn, "SELECT * FROM assessors")
print(all_assessors)

# Check pest 8
cat("\n=== PEST 8 ===\n")
pest <- dbGetQuery(conn, "SELECT * FROM pests WHERE idPest = 8")
print(pest)

# Check if assessment 8 data can be joined properly
cat("\n=== SIMULATED JOIN FOR ASSESSMENT 8 ===\n")
joined <- dbGetQuery(conn, "
  SELECT
    a.idAssessment,
    a.idPest,
    a.idAssessor,
    p.scientificName,
    p.eppoCode,
    ass.assessorName as fullName,
    ass.email
  FROM assessments a
  LEFT JOIN pests p ON a.idPest = p.idPest
  LEFT JOIN assessors ass ON a.idAssessor = ass.idAssessor
  WHERE a.idAssessment = 8
")
print(joined)

# Check for any NULL values
cat("\n=== CHECKING FOR NULL VALUES IN JOINED DATA ===\n")
cat("assessorName is NULL:", is.na(joined$fullName) || is.null(joined$fullName) || joined$fullName == "", "\n")

# Check column names in assessors table
cat("\n=== ACTUAL ASSESSORS COLUMN NAMES ===\n")
sample <- dbGetQuery(conn, "SELECT * FROM assessors LIMIT 1")
cat("Column names:", paste(colnames(sample), collapse = ", "), "\n")

dbDisconnect(conn)
