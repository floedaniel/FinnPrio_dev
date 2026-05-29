library(DBI)
library(RSQLite)


DB_PATH <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/daniel_database_2026/daniel_v009_2026-04-20T11-16-00_sdm.db"

con <- dbConnect(SQLite(), DB_PATH)

# Pathway-related table structures
cat("=== entryPathways ===\n")
print(dbGetQuery(con, "PRAGMA table_info(entryPathways)"))

cat("\n=== pathways ===\n")
print(dbGetQuery(con, "PRAGMA table_info(pathways)"))

cat("\n=== pathwayQuestions ===\n")
print(dbGetQuery(con, "PRAGMA table_info(pathwayQuestions)"))

cat("\n=== pathwayAnswers ===\n")
print(dbGetQuery(con, "PRAGMA table_info(pathwayAnswers)"))

# How many pathways per assessment?
cat("\n=== Pathways per assessment ===\n")
print(dbGetQuery(con, "
  SELECT a.idAssessment, p.scientificName, COUNT(ep.idEntryPathway) as n_pathways
  FROM assessments a
  JOIN pests p ON a.idPest = p.idPest
  LEFT JOIN entryPathways ep ON a.idAssessment = ep.idAssessment
  GROUP BY a.idAssessment
  ORDER BY n_pathways DESC
  LIMIT 10
"))

# How many pathway answers per assessment vs expected?
cat("\n=== Pathway answers per assessment ===\n")
print(dbGetQuery(con, "
  SELECT ep.idAssessment, COUNT(DISTINCT ep.idEntryPathway) as n_pathways,
         COUNT(pa.idPathAnswer) as n_answers,
         SUM(CASE WHEN pa.justification IS NOT NULL AND pa.justification != '' THEN 1 ELSE 0 END) as n_with_justification
  FROM entryPathways ep
  LEFT JOIN pathwayAnswers pa ON ep.idEntryPathway = pa.idEntryPathway
  GROUP BY ep.idAssessment
"))

cat("\n=== Total pathway questions ===\n")
print(dbGetQuery(con, "SELECT COUNT(*) as n FROM pathwayQuestions"))

dbDisconnect(con)


# -------------------------------------------------------------------------

DB_PATH <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/daniel_database_2026/daniel_v009_2026-04-20T11-16-00_sdm.db"

con <- dbConnect(SQLite(), DB_PATH)

t <- dbGetQuery(con, "
  SELECT ep.idAssessment, p.scientificName, pw.name as pathway,
         ep.idEntryPathway, pa.idPathQuestion,
         pa.min, pa.likely, pa.max,
         CASE WHEN pa.justification IS NOT NULL AND pa.justification != '' 
              THEN 'yes' ELSE 'no' END as has_justification
  FROM entryPathways ep
  JOIN pathwayAnswers pa ON ep.idEntryPathway = pa.idEntryPathway
  JOIN assessments a ON ep.idAssessment = a.idAssessment
  JOIN pests p ON a.idPest = p.idPest
  JOIN pathways pw ON ep.idPathway = pw.idPathway
  ORDER BY ep.idAssessment, ep.idEntryPathway, pa.idPathQuestion
")

dbDisconnect(con)
