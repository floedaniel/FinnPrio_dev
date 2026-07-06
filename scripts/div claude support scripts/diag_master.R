library(DBI)
library(RSQLite)
con <- dbConnect(SQLite(), "C:/Dev/FinnPrio/FinnPRIO_development/databases/master database/finnprio_master.db")

dups <- dbGetQuery(con, "
  SELECT p.eppoCode, p.scientificName, COUNT(*) AS n,
         GROUP_CONCAT(a.idAssessment) AS ids,
         GROUP_CONCAT(a.endDate)      AS end_dates
  FROM assessments a JOIN pests p ON p.idPest = a.idPest
  GROUP BY p.idPest HAVING n > 1
  ORDER BY p.scientificName
")
cat("Pests with multiple assessments:\n")
print(dups)

for (i in seq_len(nrow(dups))) {
  ids <- as.integer(strsplit(dups$ids[i], ",")[[1]])
  sims <- dbGetQuery(con, paste0(
    "SELECT idAssessment, MAX(date) AS max_sim FROM simulations ",
    "WHERE idAssessment IN (", paste(ids, collapse=","), ") ",
    "GROUP BY idAssessment"))
  cat("\n", dups$scientificName[i], "\n")
  cat("  Assessment IDs:", paste(ids, collapse=", "), "\n")
  cat("  End dates:     ", dups$end_dates[i], "\n")
  if (nrow(sims) > 0) { cat("  Simulations:\n"); print(sims) } else cat("  No simulations\n")
}
dbDisconnect(con)
