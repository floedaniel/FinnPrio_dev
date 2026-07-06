
# ==============================================================================
# repair_master_duplicates.R
# Removes duplicate assessments from finnprio_master.db.
# For each pest with multiple assessments, keeps the one with:
#   1. Latest simulation date (primary criterion)
#   2. Latest endDate as fallback when sim dates are equal or absent
# Deletes all related rows in FK-safe order.
# ==============================================================================

MASTER_DB  <- "C:/Dev/FinnPrio/FinnPRIO_development/databases/master_database/finnprio_master.db"
DRY_RUN    <- FALSE   # set TRUE to preview without deleting

library(DBI)
library(RSQLite)
library(dplyr)

# ── helpers ───────────────────────────────────────────────────────────────────
delete_assessments <- function(con, ids) {
  if (length(ids) == 0) return(invisible(NULL))
  id_str <- paste(ids, collapse = ",")

  sim_ids <- dbGetQuery(con, sprintf(
    "SELECT idSimulation FROM simulations WHERE idAssessment IN (%s)", id_str))$idSimulation
  if (length(sim_ids) > 0) {
    dbExecute(con, sprintf("DELETE FROM simulationSummaries WHERE idSimulation IN (%s)",
                           paste(sim_ids, collapse = ",")))
    dbExecute(con, sprintf("DELETE FROM simulations WHERE idSimulation IN (%s)",
                           paste(sim_ids, collapse = ",")))
  }
  ep_ids <- dbGetQuery(con, sprintf(
    "SELECT idEntryPathway FROM entryPathways WHERE idAssessment IN (%s)", id_str))$idEntryPathway
  if (length(ep_ids) > 0) {
    dbExecute(con, sprintf("DELETE FROM pathwayAnswers WHERE idEntryPathway IN (%s)",
                           paste(ep_ids, collapse = ",")))
    dbExecute(con, sprintf("DELETE FROM entryPathways WHERE idEntryPathway IN (%s)",
                           paste(ep_ids, collapse = ",")))
  }
  dbExecute(con, sprintf("DELETE FROM threatXassessment WHERE idAssessment IN (%s)", id_str))
  dbExecute(con, sprintf("DELETE FROM answers WHERE idAssessment IN (%s)", id_str))
  dbExecute(con, sprintf("DELETE FROM assessments WHERE idAssessment IN (%s)", id_str))
}

# ── backup ────────────────────────────────────────────────────────────────────
backup <- sub("\\.db$", paste0("_pre_repair_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".db"), MASTER_DB)
stopifnot(file.copy(MASTER_DB, backup))
cat("Backup:", basename(backup), "\n\n")

con <- dbConnect(SQLite(), MASTER_DB)
on.exit(dbDisconnect(con), add = TRUE)

# ── find duplicates ───────────────────────────────────────────────────────────
dups <- dbGetQuery(con, "
  SELECT p.idPest, p.eppoCode, p.scientificName, COUNT(*) AS n,
         GROUP_CONCAT(a.idAssessment) AS ids
  FROM assessments a JOIN pests p ON p.idPest = a.idPest
  GROUP BY p.idPest HAVING n > 1
  ORDER BY p.scientificName
")

if (nrow(dups) == 0) {
  cat("No duplicate assessments found. Nothing to do.\n")
  q("no")
}

cat(sprintf("Found %d pest(s) with multiple assessments:\n\n", nrow(dups)))

to_delete <- integer(0)

for (i in seq_len(nrow(dups))) {
  ids <- as.integer(strsplit(dups$ids[i], ",")[[1]])

  # Gather endDate and latest sim date per assessment
  info <- dbGetQuery(con, sprintf("
    SELECT a.idAssessment, a.endDate,
           MAX(s.date) AS max_sim
    FROM assessments a
    LEFT JOIN simulations s ON s.idAssessment = a.idAssessment
    WHERE a.idAssessment IN (%s)
    GROUP BY a.idAssessment
    ORDER BY max_sim DESC NULLS LAST, a.endDate DESC NULLS LAST
  ", paste(ids, collapse = ",")))

  keep   <- info$idAssessment[1]   # top row = best by sim date then endDate
  remove <- info$idAssessment[-1]

  cat(sprintf("%-45s  (%s)\n", dups$scientificName[i], dups$eppoCode[i]))
  for (j in seq_len(nrow(info))) {
    flag <- if (info$idAssessment[j] == keep) " KEEP  " else " DELETE"
    cat(sprintf("  [%s] id=%-4d  endDate=%-25s  sim=%s\n",
                flag,
                info$idAssessment[j],
                if (is.na(info$endDate[j])) "NULL" else info$endDate[j],
                if (is.na(info$max_sim[j])) "none" else info$max_sim[j]))
  }
  cat("\n")

  to_delete <- c(to_delete, remove)
}

cat(sprintf("Total assessments to delete: %d\n\n", length(to_delete)))

if (DRY_RUN) {
  cat("DRY_RUN = TRUE — no changes made. Set DRY_RUN <- FALSE to apply.\n")
} else {
  delete_assessments(con, to_delete)

  final <- dbGetQuery(con, "
    SELECT (SELECT COUNT(*) FROM assessments) AS assessments,
           (SELECT COUNT(*) FROM pests)       AS pests")
  cat(sprintf("Done. Assessments: %d  Pests: %d\n",
              final$assessments, final$pests))
}
