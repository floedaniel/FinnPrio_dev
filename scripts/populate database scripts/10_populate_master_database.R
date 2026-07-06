
# ==============================================================================
# 10_POPULATE_MASTER_DATABASE.R
# Merges yearly FinnPRIO databases into a cumulative master database.
#
# Deduplication rule (by EPPO code):
#   - If pest is new: insert all its data.
#   - If pest already exists in master:
#       * Compare max simulation date (master vs source).
#       * If source is newer (or only source has a simulation): replace —
#         delete the master's assessment block and insert the source version.
#       * If master is same/newer, or neither has a simulation and master
#         assessment endDate >= source endDate: skip.
#   - Assessors deduplicated by firstName + lastName.
#
# After merging, assessments with no justifications, no values, AND no
# simulations are safely removed (all related rows deleted in FK order).
# Master is backed up before any changes.
# ==============================================================================

# ==============================================================================
# 0. CONFIGURATION
# ==============================================================================

MASTER_DB <- "C:/Dev/FinnPrio/FinnPRIO_development/databases/master_database/finnprio_master.db"

SOURCE_FILES <- c(
  "C:/Dev/FinnPrio/FinnPRIO_development/databases/master_database/yearly copies/FinnPrio_fg9_batch_1_2025.db",
  "C:/Dev/FinnPrio/FinnPRIO_development/databases/master_database/yearly copies/master_database_2026.db"
)

# ==============================================================================
# clean-up
# ==============================================================================

DELETE_EMPTY_ASSESSMENTS <- TRUE   # remove assessments with no content after merge

REFERENCE_SPECIES <- c("ERWIAM", "AGRLAX" ) # excluded from plots

# ==============================================================================
# 1. LIBRARIES
# ==============================================================================

library(DBI)
library(RSQLite)
library(dplyr)

# ==============================================================================
# 2. HELPERS
# ==============================================================================

stop_if   <- function(cond, msg) if (cond) stop(msg, call. = FALSE)
warn_skip <- function(msg) { cat("  [WARN]", msg, "\n"); invisible(NULL) }

safe_read <- function(con, table) {
  tryCatch(dbReadTable(con, table), error = function(e) {
    warn_skip(paste("Cannot read", table, ":", e$message)); NULL
  })
}

# Delete an assessment block from con_master by a vector of idAssessment values.
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

# ==============================================================================
# 3. VALIDATE INPUTS
# ==============================================================================

stop_if(!file.exists(MASTER_DB), paste("Master DB not found:", MASTER_DB))

missing_src <- SOURCE_FILES[!file.exists(SOURCE_FILES)]
if (length(missing_src) > 0) {
  cat("[WARN] Source file(s) not found — will be skipped:\n")
  for (f in missing_src) cat("  ", f, "\n")
}
SOURCE_FILES <- SOURCE_FILES[file.exists(SOURCE_FILES)]
stop_if(length(SOURCE_FILES) == 0, "No source files found.")

cat("Master DB:   ", MASTER_DB, "\n")
cat("Sources:     ", length(SOURCE_FILES), "\n")
for (f in SOURCE_FILES) cat("  ", basename(f), "\n")
cat("\n")

# ==============================================================================
# 4. BACKUP MASTER
# ==============================================================================

backup_path <- file.path(dirname(MASTER_DB), "backups",
                         sub("\\.db$",
                             paste0("_backup_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".db"),
                             basename(MASTER_DB)))
stop_if(!file.copy(MASTER_DB, backup_path),
        paste("Backup failed — check disk space.\n  To:", backup_path))
cat("Backup created:", basename(backup_path), "\n\n")

# ==============================================================================
# 5. OPEN MASTER
# ==============================================================================

con_master <- dbConnect(SQLite(), MASTER_DB)
on.exit(dbDisconnect(con_master), add = TRUE)
dbExecute(con_master, "UPDATE dbStatus SET inUse = 0, timeStamp = CURRENT_TIMESTAMP")

existing_eppo <- dbGetQuery(con_master, "SELECT eppoCode FROM pests")$eppoCode
existing_eppo <- trimws(existing_eppo[!is.na(existing_eppo) & nchar(trimws(existing_eppo)) > 0])

cat(sprintf("Master currently holds: %d pests, %d with EPPO code\n\n",
            dbGetQuery(con_master, "SELECT COUNT(*) FROM pests")[[1]],
            length(existing_eppo)))

# ==============================================================================
# 6. MERGE LOOP
# ==============================================================================

totals <- list(pests_added = 0L, pests_replaced = 0L, pests_skipped = 0L,
               assessors_new = 0L, assessments = 0L,
               answers = 0L, pathway_answers = 0L,
               simulations = 0L, sim_summaries = 0L)

for (src_path in SOURCE_FILES) {
  src_name <- basename(src_path)
  cat(rep("─", 60), "\n", sep = "")
  cat("Source:", src_name, "\n")

  con_src <- tryCatch(dbConnect(SQLite(), src_path), error = function(e) {
    warn_skip(paste("Cannot open", src_name, ":", e$message)); NULL
  })
  if (is.null(con_src)) next

  # Pre-load all tables in one connection so the pest loop can compare dates
  or_empty <- function(x) if (is.null(x)) data.frame() else x
  src_pests       <- or_empty(safe_read(con_src, "pests"))
  src_assessors   <- or_empty(safe_read(con_src, "assessors"))
  src_assessments <- or_empty(safe_read(con_src, "assessments"))
  src_simulations <- or_empty(safe_read(con_src, "simulations"))
  src_answers     <- or_empty(safe_read(con_src, "answers"))
  src_threats     <- or_empty(safe_read(con_src, "threatXassessment"))
  src_ep          <- or_empty(safe_read(con_src, "entryPathways"))
  src_pa          <- or_empty(safe_read(con_src, "pathwayAnswers"))
  src_ss          <- or_empty(safe_read(con_src, "simulationSummaries"))
  dbDisconnect(con_src)

  if (nrow(src_pests) == 0) { cat("  No pests found — skipping.\n"); next }

  # ── Assessors ────────────────────────────────────────────────────────────────
  assessor_map  <- data.frame(old_id = integer(), new_id = integer())

  if (nrow(src_assessors) > 0) {
    for (i in seq_len(nrow(src_assessors))) {
      a <- src_assessors[i, ]
      existing <- dbGetQuery(con_master,
        "SELECT idAssessor FROM assessors WHERE firstName = ? AND lastName = ?",
        params = list(a$firstName, a$lastName))
      if (nrow(existing) > 0) {
        new_id <- existing$idAssessor[1]
      } else {
        dbExecute(con_master,
          "INSERT INTO assessors (firstName, lastName, email) VALUES (?, ?, ?)",
          params = list(a$firstName, a$lastName, a$email))
        new_id <- dbGetQuery(con_master, "SELECT last_insert_rowid() AS id")$id
        totals$assessors_new <- totals$assessors_new + 1L
      }
      assessor_map <- rbind(assessor_map, data.frame(old_id = a$idAssessor, new_id = new_id))
    }
  }

  # ── Pest loop: decide add / replace / skip ────────────────────────────────────
  # action map: old pest ID -> list(action, master_pest_id)
  pest_action <- data.frame(
    old_id         = integer(),
    new_id         = integer(),   # idPest in master
    action         = character(), # "add" | "replace" | "skip"
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(src_pests))) {
    p    <- src_pests[i, ]
    eppo <- if (!is.na(p$eppoCode)) trimws(p$eppoCode) else ""

    # ── Reference species: never imported from source (existing master copies left as-is) ──
    if (nchar(eppo) > 0 && toupper(eppo) %in% toupper(REFERENCE_SPECIES)) {
      cat(sprintf("  SKIP (reference species): %s (%s)\n", p$scientificName, eppo))
      next
    }

    if (nchar(eppo) == 0 || !toupper(eppo) %in% toupper(existing_eppo)) {
      # ── New pest: insert ──────────────────────────────────────────────────────
      dbExecute(con_master,
        "INSERT INTO pests (scientificName, eppoCode, synonyms, vernacularName,
                            idTaxa, idQuarantineStatus, inEurope, gbifTaxonKey)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        params = list(p$scientificName, p$eppoCode, p$synonyms, p$vernacularName,
                      p$idTaxa, p$idQuarantineStatus, p$inEurope, p$gbifTaxonKey))
      new_id <- dbGetQuery(con_master, "SELECT last_insert_rowid() AS id")$id
      pest_action <- rbind(pest_action, data.frame(old_id = p$idPest, new_id = new_id,
                                                    action = "add", stringsAsFactors = FALSE))
      if (nchar(eppo) > 0) existing_eppo <- c(existing_eppo, eppo)
      totals$pests_added <- totals$pests_added + 1L

    } else {
      # ── Existing pest: compare simulation dates ───────────────────────────────
      master_pest_id <- dbGetQuery(con_master,
        "SELECT idPest FROM pests WHERE UPPER(eppoCode) = UPPER(?)",
        params = list(eppo))$idPest[1]

      master_max_sim <- dbGetQuery(con_master, "
        SELECT MAX(s.date) AS d
        FROM simulations s
        JOIN assessments a ON a.idAssessment = s.idAssessment
        WHERE a.idPest = ?", params = list(master_pest_id))$d

      src_pest_ass_ids <- src_assessments$idAssessment[
        src_assessments$idPest == p$idPest]
      src_sims_for_pest <- if (nrow(src_simulations) > 0 && length(src_pest_ass_ids) > 0)
        src_simulations[src_simulations$idAssessment %in% src_pest_ass_ids, ]
      else data.frame()
      src_max_sim <- if (nrow(src_sims_for_pest) > 0) max(src_sims_for_pest$date) else NA

      # Fallback: compare assessment endDate when no simulations exist on either side
      master_max_end <- dbGetQuery(con_master, "
        SELECT MAX(endDate) AS d FROM assessments WHERE idPest = ?",
        params = list(master_pest_id))$d
      src_max_end <- if (length(src_pest_ass_ids) > 0)
        max(src_assessments$endDate[src_assessments$idAssessment %in% src_pest_ass_ids],
            na.rm = TRUE)
      else NA_character_

      # Decision
      source_wins <- (
        (!is.na(src_max_sim) && (is.na(master_max_sim) || src_max_sim > master_max_sim)) ||
        (is.na(src_max_sim) && is.na(master_max_sim) &&
         !is.na(src_max_end) && (is.na(master_max_end) || src_max_end > master_max_end))
      )

      if (source_wins) {
        master_ass_ids <- dbGetQuery(con_master,
          "SELECT idAssessment FROM assessments WHERE idPest = ?",
          params = list(master_pest_id))$idAssessment
        delete_assessments(con_master, master_ass_ids)

        cat(sprintf("  REPLACE: %s (%s) — source sim %s > master sim %s\n",
                    p$scientificName, eppo,
                    if (!is.na(src_max_sim)) src_max_sim else src_max_end,
                    if (!is.na(master_max_sim)) master_max_sim else master_max_end))

        pest_action <- rbind(pest_action,
          data.frame(old_id = p$idPest, new_id = master_pest_id,
                     action = "replace", stringsAsFactors = FALSE))
        totals$pests_replaced <- totals$pests_replaced + 1L
      } else {
        pest_action <- rbind(pest_action,
          data.frame(old_id = p$idPest, new_id = master_pest_id,
                     action = "skip", stringsAsFactors = FALSE))
        totals$pests_skipped <- totals$pests_skipped + 1L
      }
    }
  }

  n_add     <- sum(pest_action$action == "add")
  n_replace <- sum(pest_action$action == "replace")
  n_skip    <- sum(pest_action$action == "skip")
  cat(sprintf("  Pests: %d added, %d replaced, %d skipped\n", n_add, n_replace, n_skip))

  # ── Assessments — add/replace only ────────────────────────────────────────────
  active_pests    <- pest_action[pest_action$action %in% c("add", "replace"), ]
  assessment_map  <- data.frame(old_id = integer(), new_id = integer())

  if (nrow(active_pests) > 0 && nrow(src_assessments) > 0) {
    # Keep only the best assessment per MASTER pest ID (newest sim date → latest endDate).
    # Two failure modes both handled here:
    #   1. One source pest has multiple assessments (e.g. batch + original run)
    #   2. Two source pests share an EPPO code (e.g. capitalisation variants like
    #      "Agilus anxius" vs "Agilus Anxius"), one gets action=add, one action=replace,
    #      but both map to the same master pest ID → must keep only the best of all.
    pool <- src_assessments[src_assessments$idPest %in% active_pests$old_id, , drop = FALSE]
    pool$master_pest_id <- active_pests$new_id[match(pool$idPest, active_pests$old_id)]
    best_ids <- vapply(unique(pool$master_pest_id), function(mpid) {
      rows <- pool[pool$master_pest_id == mpid, , drop = FALSE]
      if (nrow(rows) == 1L) return(rows$idAssessment)
      sims_for <- if (nrow(src_simulations) > 0)
        src_simulations[src_simulations$idAssessment %in% rows$idAssessment, ]
      else data.frame()
      rows$ms <- vapply(rows$idAssessment, function(aid) {
        d <- sims_for$date[sims_for$idAssessment == aid]
        if (!length(d)) NA_character_ else max(d)
      }, character(1))
      rows <- rows[order(is.na(rows$ms),
                         -xtfrm(ifelse(is.na(rows$ms), "", rows$ms)),
                         -xtfrm(ifelse(is.na(rows$endDate), "", rows$endDate))), ]
      rows$idAssessment[1L]
    }, integer(1))
    n_deduped <- nrow(pool) - length(best_ids)
    if (n_deduped > 0)
      cat(sprintf("  [INFO] Dropped %d duplicate source assessment(s) — kept best per master pest\n",
                  n_deduped))
    copy_ass <- src_assessments[src_assessments$idAssessment %in% best_ids, ]

    for (i in seq_len(nrow(copy_ass))) {
      ass          <- copy_ass[i, ]
      new_pest     <- active_pests$new_id[active_pests$old_id == ass$idPest]
      new_assessor <- assessor_map$new_id[assessor_map$old_id == ass$idAssessor]

      if (length(new_pest) == 0 || length(new_assessor) == 0) {
        warn_skip(paste("Assessment", ass$idAssessment, "— missing mapping")); next
      }
      dbExecute(con_master,
        "INSERT INTO assessments (idPest, idAssessor, startDate, endDate,
                                  finished, valid, notes, version, hosts,
                                  potentialEntryPathways, reference)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params = list(new_pest[1], new_assessor[1],
                      ass$startDate, ass$endDate, ass$finished, ass$valid,
                      ass$notes, ass$version, ass$hosts,
                      ass$potentialEntryPathways, ass$reference))
      new_id <- dbGetQuery(con_master, "SELECT last_insert_rowid() AS id")$id
      assessment_map <- rbind(assessment_map,
                              data.frame(old_id = ass$idAssessment, new_id = new_id))
      totals$assessments <- totals$assessments + 1L
    }
  }
  cat(sprintf("  Assessments inserted: %d\n", nrow(assessment_map)))
  if (nrow(assessment_map) == 0) next

  # ── Answers ───────────────────────────────────────────────────────────────────
  n_ans <- 0L
  if (nrow(src_answers) > 0) {
    rows <- src_answers[src_answers$idAssessment %in% assessment_map$old_id, ]
    for (i in seq_len(nrow(rows))) {
      r       <- rows[i, ]
      new_ass <- assessment_map$new_id[assessment_map$old_id == r$idAssessment]
      if (length(new_ass) == 0) next
      dbExecute(con_master,
        "INSERT INTO answers (idAssessment, idQuestion, min, likely, max, justification)
         VALUES (?, ?, ?, ?, ?, ?)",
        params = list(new_ass[1], r$idQuestion, r$min, r$likely, r$max, r$justification))
      n_ans <- n_ans + 1L
    }
  }
  totals$answers <- totals$answers + n_ans
  cat(sprintf("  Answers: %d\n", n_ans))

  # ── threatXassessment ─────────────────────────────────────────────────────────
  if (nrow(src_threats) > 0) {
    rows <- src_threats[src_threats$idAssessment %in% assessment_map$old_id, ]
    for (i in seq_len(nrow(rows))) {
      r       <- rows[i, ]
      new_ass <- assessment_map$new_id[assessment_map$old_id == r$idAssessment]
      if (length(new_ass) == 0) next
      dbExecute(con_master,
        "INSERT INTO threatXassessment (idAssessment, idThrSect) VALUES (?, ?)",
        params = list(new_ass[1], r$idThrSect))
    }
  }

  # ── entryPathways ─────────────────────────────────────────────────────────────
  ep_map <- data.frame(old_id = integer(), new_id = integer())
  if (nrow(src_ep) > 0) {
    rows <- src_ep[src_ep$idAssessment %in% assessment_map$old_id, ]
    for (i in seq_len(nrow(rows))) {
      r       <- rows[i, ]
      new_ass <- assessment_map$new_id[assessment_map$old_id == r$idAssessment]
      if (length(new_ass) == 0) next
      dbExecute(con_master,
        "INSERT INTO entryPathways (idAssessment, idPathway) VALUES (?, ?)",
        params = list(new_ass[1], r$idPathway))
      new_id <- dbGetQuery(con_master, "SELECT last_insert_rowid() AS id")$id
      ep_map <- rbind(ep_map, data.frame(old_id = r$idEntryPathway, new_id = new_id))
    }
  }

  # ── pathwayAnswers ────────────────────────────────────────────────────────────
  n_pa <- 0L
  if (nrow(src_pa) > 0 && nrow(ep_map) > 0) {
    rows <- src_pa[src_pa$idEntryPathway %in% ep_map$old_id, ]
    for (i in seq_len(nrow(rows))) {
      r      <- rows[i, ]
      new_ep <- ep_map$new_id[ep_map$old_id == r$idEntryPathway]
      if (length(new_ep) == 0) next
      dbExecute(con_master,
        "INSERT OR IGNORE INTO pathwayAnswers
           (idEntryPathway, idPathQuestion, min, likely, max, justification)
         VALUES (?, ?, ?, ?, ?, ?)",
        params = list(new_ep[1], r$idPathQuestion, r$min, r$likely, r$max, r$justification))
      n_pa <- n_pa + 1L
    }
  }
  totals$pathway_answers <- totals$pathway_answers + n_pa
  cat(sprintf("  Pathway answers: %d\n", n_pa))

  # ── Simulations ───────────────────────────────────────────────────────────────
  sim_map <- data.frame(old_id = integer(), new_id = integer())
  if (nrow(src_simulations) > 0) {
    rows <- src_simulations[src_simulations$idAssessment %in% assessment_map$old_id, ]
    for (i in seq_len(nrow(rows))) {
      r       <- rows[i, ]
      new_ass <- assessment_map$new_id[assessment_map$old_id == r$idAssessment]
      if (length(new_ass) == 0) next
      dbExecute(con_master,
        "INSERT INTO simulations (idAssessment, iterations, lambda, weight1, weight2, date)
         VALUES (?, ?, ?, ?, ?, ?)",
        params = list(new_ass[1], r$iterations, r$lambda, r$weight1, r$weight2, r$date))
      new_id <- dbGetQuery(con_master, "SELECT last_insert_rowid() AS id")$id
      sim_map <- rbind(sim_map, data.frame(old_id = r$idSimulation, new_id = new_id))
    }
  }
  totals$simulations <- totals$simulations + nrow(sim_map)

  # ── Simulation summaries ──────────────────────────────────────────────────────
  n_ss <- 0L
  if (nrow(src_ss) > 0 && nrow(sim_map) > 0) {
    rows <- src_ss[src_ss$idSimulation %in% sim_map$old_id, ]
    for (i in seq_len(nrow(rows))) {
      r       <- rows[i, ]
      new_sim <- sim_map$new_id[sim_map$old_id == r$idSimulation]
      if (length(new_sim) == 0) next
      dbExecute(con_master,
        "INSERT INTO simulationSummaries
           (idSimulation, variable, min, q5, q25, median, q75, q95, max, mean)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params = list(new_sim[1], r$variable,
                      r$min, r$q5, r$q25, r$median, r$q75, r$q95, r$max, r$mean))
      n_ss <- n_ss + 1L
    }
  }
  totals$sim_summaries <- totals$sim_summaries + n_ss
  cat(sprintf("  Simulations: %d  |  Summaries: %d\n", nrow(sim_map), n_ss))
}

# ==============================================================================
# 7. SAFE DELETION OF EMPTY ASSESSMENTS
# "Empty" = no justification AND no values AND no simulation (all three).
# ==============================================================================

if (DELETE_EMPTY_ASSESSMENTS) {
  cat("\n", rep("─", 60), "\n", sep = "")
  cat("=== Safe deletion of empty assessments ===\n")

  empty <- dbGetQuery(con_master, "
    SELECT a.idAssessment, p.eppoCode, p.scientificName
    FROM assessments a
    JOIN pests p ON p.idPest = a.idPest
    WHERE
      NOT EXISTS (
        SELECT 1 FROM answers ans
        WHERE ans.idAssessment = a.idAssessment
          AND ans.justification IS NOT NULL AND ans.justification != ''
      )
      AND NOT EXISTS (
        SELECT 1 FROM answers ans
        WHERE ans.idAssessment = a.idAssessment
          AND ans.min IS NOT NULL AND ans.min != ''
      )
      AND NOT EXISTS (
        SELECT 1 FROM simulations s WHERE s.idAssessment = a.idAssessment
      )
  ")

  if (nrow(empty) == 0) {
    cat("  No empty assessments found.\n")
  } else {
    cat(sprintf("  Found %d empty assessment(s):\n", nrow(empty)))
    for (i in seq_len(nrow(empty)))
      cat(sprintf("    [%d] %s (%s)\n",
                  empty$idAssessment[i], empty$scientificName[i], empty$eppoCode[i]))
    delete_assessments(con_master, empty$idAssessment)
    cat(sprintf("  Deleted %d empty assessment(s) and all related rows.\n", nrow(empty)))
  }
}

# ==============================================================================
# 8. SUMMARY
# ==============================================================================

final <- dbGetQuery(con_master, "
  SELECT
    (SELECT COUNT(*) FROM pests)       AS pests,
    (SELECT COUNT(*) FROM assessors)   AS assessors,
    (SELECT COUNT(*) FROM assessments) AS assessments,
    (SELECT COUNT(*) FROM answers)     AS answers,
    (SELECT COUNT(*) FROM simulations) AS simulations
")

cat("\n", rep("=", 60), "\n", sep = "")
cat("MASTER DATABASE UPDATED\n")
cat(rep("=", 60), "\n", sep = "")
cat("Output:", MASTER_DB, "\n\n")
cat("Final counts in master:\n")
cat(sprintf("  Pests:       %d\n", final$pests))
cat(sprintf("  Assessors:   %d\n", final$assessors))
cat(sprintf("  Assessments: %d\n", final$assessments))
cat(sprintf("  Answers:     %d\n", final$answers))
cat(sprintf("  Simulations: %d\n", final$simulations))
cat("\nThis run:\n")
cat(sprintf("  Pests added:          %d\n", totals$pests_added))
cat(sprintf("  Pests replaced:       %d\n", totals$pests_replaced))
cat(sprintf("  Pests skipped:        %d\n", totals$pests_skipped))
cat(sprintf("  Assessors (new):      %d\n", totals$assessors_new))
cat(sprintf("  Assessments:          %d\n", totals$assessments))
cat(sprintf("  Answers:              %d\n", totals$answers))
cat(sprintf("  Pathway answers:      %d\n", totals$pathway_answers))
cat(sprintf("  Simulations:          %d\n", totals$simulations))
cat(sprintf("  Simulation summaries: %d\n", totals$sim_summaries))
cat(rep("=", 60), "\n", sep = "")
