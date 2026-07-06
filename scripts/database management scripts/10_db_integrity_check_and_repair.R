
# 10_db_integrity_check_and_repair.R
# Checks a FinnPRIO database for structural integrity issues and optionally
# repairs them. Run with DRY_RUN = TRUE first to see what would be changed.
#
# Checks performed:
#   1. Duplicate pathway answers   (idEntryPathway + idPathQuestion)
#   2. Orphaned pathway answers    (idEntryPathway not in entryPathways)
#   3. Duplicate answers           (idAssessment + idQuestion)
#   4. Orphaned answers            (idAssessment not in assessments)
#   5. Orphaned entryPathways      (idAssessment not in assessments)
#   6. Orphaned threatXassessment  (idAssessment not in assessments)
#   7. Orphaned simulations        (idAssessment not in assessments)
#   8. Orphaned simulationSummaries(idSimulation not in simulations)
#   9. Assessments with missing pest or assessor FK
#  10. Simulations with no summaries

library(DBI)
library(RSQLite)
library(dplyr)

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH  <- "C:/Dev/FinnPrio/FinnPRIO_development/databases/finnprio_2026/iben_database_2026/4_master/iben.db"

DRY_RUN  <- TRUE   # TRUE = report only, no changes made
                   # FALSE = apply all repairs

# ==============================================================================
# CONNECT
# ==============================================================================

con <- dbConnect(RSQLite::SQLite(), DB_PATH)
dbExecute(con, "PRAGMA foreign_keys = OFF")   # off so we can inspect/repair freely
on.exit({ dbExecute(con, "PRAGMA foreign_keys = ON"); dbDisconnect(con) }, add = TRUE)

cat("Database:", DB_PATH, "\n")
cat("Mode:    ", if (DRY_RUN) "DRY RUN (no changes)" else "REPAIR (changes will be applied)", "\n")
cat(strrep("=", 72), "\n\n")

issues_found <- 0L

report <- function(title, n, detail = NULL) {
  issues_found <<- issues_found + n
  status <- if (n == 0) "OK" else if (DRY_RUN) sprintf("ISSUE (%d rows)", n) else sprintf("FIXED (%d rows)", n)
  cat(sprintf("  %-52s [%s]\n", title, status))
  if (!is.null(detail) && nrow(detail) > 0) {
    print(detail, row.names = FALSE)
    cat("\n")
  }
}

repair <- function(sql) {
  if (!DRY_RUN) dbExecute(con, sql)
}

# ==============================================================================
# TABLE COUNTS
# ==============================================================================

cat("Row counts:\n")
for (tbl in c("assessors", "pests", "assessments", "answers", "pathwayAnswers",
              "entryPathways", "threatXassessment", "simulations", "simulationSummaries")) {
  n <- dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", tbl))$n
  cat(sprintf("  %-30s %d\n", tbl, n))
}
cat("\n")

# ==============================================================================
# CHECK 1: Duplicate pathway answers
# ==============================================================================

cat("Integrity checks:\n")

dups_pa <- dbGetQuery(con, "
  SELECT idEntryPathway, idPathQuestion, COUNT(*) AS n
  FROM pathwayAnswers
  GROUP BY idEntryPathway, idPathQuestion
  HAVING COUNT(*) > 1
")

report("1. Duplicate pathwayAnswers", nrow(dups_pa),
       if (nrow(dups_pa) > 0) dups_pa else NULL)

if (nrow(dups_pa) > 0) {
  # Keep the row with most non-NULL PERT fields; delete the rest
  # Strategy: keep the MAX rowid per group (last inserted), delete others
  repair("
    DELETE FROM pathwayAnswers
    WHERE rowid NOT IN (
      SELECT MAX(rowid)
      FROM pathwayAnswers
      GROUP BY idEntryPathway, idPathQuestion
    )
  ")
}

# ==============================================================================
# CHECK 2: Orphaned pathway answers (no parent entryPathway)
# ==============================================================================

orph_pa <- dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM pathwayAnswers
  WHERE idEntryPathway NOT IN (SELECT idEntryPathway FROM entryPathways)
")$n

report("2. Orphaned pathwayAnswers", orph_pa)
repair("DELETE FROM pathwayAnswers WHERE idEntryPathway NOT IN (SELECT idEntryPathway FROM entryPathways)")

# ==============================================================================
# CHECK 3: Duplicate answers (same question answered twice for same assessment)
# ==============================================================================

dups_ans <- dbGetQuery(con, "
  SELECT idAssessment, idQuestion, COUNT(*) AS n
  FROM answers
  GROUP BY idAssessment, idQuestion
  HAVING COUNT(*) > 1
")

report("3. Duplicate answers", nrow(dups_ans),
       if (nrow(dups_ans) > 0) dups_ans else NULL)

if (nrow(dups_ans) > 0) {
  repair("
    DELETE FROM answers
    WHERE rowid NOT IN (
      SELECT MAX(rowid)
      FROM answers
      GROUP BY idAssessment, idQuestion
    )
  ")
}

# ==============================================================================
# CHECK 4: Orphaned answers (idAssessment not in assessments)
# ==============================================================================

orph_ans <- dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM answers
  WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)
")$n

report("4. Orphaned answers", orph_ans)
repair("DELETE FROM answers WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)")

# ==============================================================================
# CHECK 5: Orphaned entryPathways
# ==============================================================================

orph_ep <- dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM entryPathways
  WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)
")$n

report("5. Orphaned entryPathways", orph_ep)
repair("DELETE FROM entryPathways WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)")

# ==============================================================================
# CHECK 6: Orphaned threatXassessment
# ==============================================================================

orph_thr <- dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM threatXassessment
  WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)
")$n

report("6. Orphaned threatXassessment", orph_thr)
repair("DELETE FROM threatXassessment WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)")

# ==============================================================================
# CHECK 7: Orphaned simulations
# ==============================================================================

orph_sim <- dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM simulations
  WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)
")$n

report("7. Orphaned simulations", orph_sim)
repair("DELETE FROM simulations WHERE idAssessment NOT IN (SELECT idAssessment FROM assessments)")

# ==============================================================================
# CHECK 8: Orphaned simulationSummaries
# ==============================================================================

orph_ss <- dbGetQuery(con, "
  SELECT COUNT(*) AS n FROM simulationSummaries
  WHERE idSimulation NOT IN (SELECT idSimulation FROM simulations)
")$n

report("8. Orphaned simulationSummaries", orph_ss)
repair("DELETE FROM simulationSummaries WHERE idSimulation NOT IN (SELECT idSimulation FROM simulations)")

# ==============================================================================
# CHECK 9: Assessments with broken FK to pests or assessors
# ==============================================================================

broken_fk <- dbGetQuery(con, "
  SELECT a.idAssessment, a.idPest, a.idAssessor,
         CASE WHEN p.idPest IS NULL THEN 'missing pest' ELSE '' END AS pest_issue,
         CASE WHEN ao.idAssessor IS NULL THEN 'missing assessor' ELSE '' END AS assessor_issue
  FROM assessments a
  LEFT JOIN pests     p  ON p.idPest     = a.idPest
  LEFT JOIN assessors ao ON ao.idAssessor = a.idAssessor
  WHERE p.idPest IS NULL OR ao.idAssessor IS NULL
")

report("9. Assessments with broken FK (pest/assessor)", nrow(broken_fk),
       if (nrow(broken_fk) > 0) broken_fk else NULL)

# ==============================================================================
# CHECK 10: Simulations with no summaries
# ==============================================================================

sim_no_sum <- dbGetQuery(con, "
  SELECT s.idSimulation, s.idAssessment, p.eppoCode
  FROM simulations s
  JOIN assessments a ON a.idAssessment = s.idAssessment
  JOIN pests p ON p.idPest = a.idPest
  WHERE s.idSimulation NOT IN (SELECT DISTINCT idSimulation FROM simulationSummaries)
")

report("10. Simulations with no summaries", nrow(sim_no_sum),
       if (nrow(sim_no_sum) > 0) sim_no_sum else NULL)

# ==============================================================================
# SUMMARY
# ==============================================================================

cat("\n", strrep("=", 72), "\n", sep = "")
if (issues_found == 0) {
  cat("No structural issues found. Database looks clean.\n")
} else if (DRY_RUN) {
  cat(sprintf("%d issue(s) found. Set DRY_RUN = FALSE and re-run to repair.\n", issues_found))
} else {
  cat(sprintf("%d issue(s) repaired.\n", issues_found))
  cat("Run with DRY_RUN = TRUE to verify the database is now clean.\n")
}
cat(strrep("=", 72), "\n")
