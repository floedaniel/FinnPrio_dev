library(DBI)
library(RSQLite)

working_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/FinnPrio_DB.db"
corrupt_db <- "C:/Users/dafl/Desktop/FinnPRIO_dev/Selam/selam_2026_corrupt.db"

cat("=== WORKING DATABASE ASSESSORS SCHEMA ===\n")
conn1 <- dbConnect(SQLite(), working_db)
schema1 <- dbGetQuery(conn1, "PRAGMA table_info(assessors)")
print(schema1)

cat("\n=== WORKING DATABASE ASSESSORS DATA ===\n")
data1 <- dbGetQuery(conn1, "SELECT * FROM assessors LIMIT 3")
print(data1)
dbDisconnect(conn1)

cat("\n=== CORRUPT DATABASE ASSESSORS SCHEMA ===\n")
conn2 <- dbConnect(SQLite(), corrupt_db)
schema2 <- dbGetQuery(conn2, "PRAGMA table_info(assessors)")
print(schema2)

cat("\n=== CORRUPT DATABASE ASSESSORS DATA ===\n")
data2 <- dbGetQuery(conn2, "SELECT * FROM assessors")
print(data2)
dbDisconnect(conn2)
