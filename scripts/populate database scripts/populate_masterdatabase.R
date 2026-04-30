library(DBI)
library(RSQLite)
library(dplyr)

# =============================================================================
# CONFIGURATION — edit this before running
# =============================================================================

BASE_DIR <- "C:/Users/dafl/OneDrive - Folkehelseinstituttet/FinnPrio/FinnPRIO_development/databases/finnprio_2026"

OUTPUT_FOLDER <- file.path(BASE_DIR, "master_database_2026")
OUTPUT_DB     <- "master_database_2026.db"
OUTPUT_PATH   <- file.path(OUTPUT_FOLDER, OUTPUT_DB)

# =============================================================================
# HELPERS
# =============================================================================

stop_if <- function(cond, msg) if (cond) stop(msg, call. = FALSE)

warn_skip <- function(msg) { cat("  [WARN]", msg, "\n"); TRUE }

# =============================================================================
# DISCOVER SOURCE DATABASES
# =============================================================================

stop_if(!dir.exists(BASE_DIR), paste("BASE_DIR does not exist:", BASE_DIR))

master_dirs <- list.dirs(BASE_DIR, recursive = TRUE, full.names = TRUE)
master_dirs <- master_dirs[basename(master_dirs) == "4_master"]

stop_if(length(master_dirs) == 0, paste("No '4_master' folders found under:", BASE_DIR))

cat("Found", length(master_dirs), "'4_master' folder(s):\n")
for (d in master_dirs) cat("  ", d, "\n")
cat("\n")

# Collect all .db files from all 4_master folders
source_files <- data.frame(
  path      = character(),
  source_db = character(),   # parent folder name used as merge key
  stringsAsFactors = FALSE
)

for (d in master_dirs) {
  dbs <- list.files(d, pattern = "\\.db$", full.names = TRUE)

  if (length(dbs) == 0) {
    warn_skip(paste("Empty 4_master folder, skipping:", d))
    next
  }

  parent_name <- basename(dirname(d))   # e.g. "selam_database_2026"

  for (db in dbs) {
    source_files <- rbind(source_files, data.frame(
      path      = db,
      source_db = parent_name,
      stringsAsFactors = FALSE
    ))
    cat("  Source:", parent_name, "->", basename(db), "\n")
  }
}

stop_if(nrow(source_files) == 0, "No .db files found in any 4_master folder.")
cat("\nTotal source files:", nrow(source_files), "\n\n")

# =============================================================================
# BACKUP EXISTING OUTPUT + CREATE SCHEMA FROM TEMPLATE
# =============================================================================

if (!dir.exists(OUTPUT_FOLDER)) dir.create(OUTPUT_FOLDER, recursive = TRUE)

# Backup existing master if it exists
if (file.exists(OUTPUT_PATH)) {
  base_backup <- file.path(OUTPUT_FOLDER,
    paste0("master_database_2026_backup_", Sys.Date(), ".db"))

  # Find unique backup name if date collision
  backup_path <- base_backup
  suffix <- 1L
  while (file.exists(backup_path)) {
    backup_path <- sub("\\.db$", paste0("_", suffix, ".db"), base_backup)
    suffix <- suffix + 1L
  }

  ok <- file.copy(OUTPUT_PATH, backup_path)
  stop_if(!ok, paste("Backup failed. Check disk space and permissions.\n  From:", OUTPUT_PATH, "\n  To:", backup_path))
  cat("Backed up existing master to:", basename(backup_path), "\n")
  file.remove(OUTPUT_PATH)
}

# Use first source DB as schema template
template_path <- source_files$path[1]
cat("Creating output DB from template:", source_files$source_db[1], "/", basename(template_path), "\n")
ok <- file.copy(template_path, OUTPUT_PATH)
stop_if(!ok, paste("Failed to copy template DB to:", OUTPUT_PATH))

con_out <- dbConnect(SQLite(), OUTPUT_PATH)
on.exit(dbDisconnect(con_out), add = TRUE)

# Clear all data tables; keep reference tables (questions, pathways, etc.)
cat("Clearing data tables...\n")
for (tbl in c("simulationSummaries", "simulations", "pathwayAnswers",
              "entryPathways", "answers", "threatXassessment",
              "assessments", "pests", "assessors")) {
  dbExecute(con_out, paste("DELETE FROM", tbl))
}
dbExecute(con_out, "UPDATE dbStatus SET inUse = 0, timeStamp = CURRENT_TIMESTAMP")
cat("Schema ready.\n\n")

# =============================================================================
# MERGE ASSESSORS (deduplicate by firstName + lastName)
# =============================================================================
cat("=== Merging Assessors ===\n")

all_assessors <- list()
for (i in seq_len(nrow(source_files))) {
  tryCatch({
    con <- dbConnect(SQLite(), source_files$path[i])
    on.exit(dbDisconnect(con), add = TRUE)
    rows <- dbReadTable(con, "assessors")
    dbDisconnect(con); on.exit()
    if (nrow(rows) == 0) next
    rows$source_db <- source_files$source_db[i]
    all_assessors[[i]] <- rows
  }, error = function(e) warn_skip(paste("Cannot read assessors from", source_files$source_db[i], ":", e$message)))
}

all_assessors_df <- bind_rows(all_assessors)

# Detect schema: old (assessorName) vs new (firstName + lastName)
has_split <- all(c("firstName", "lastName") %in% names(all_assessors_df))

if (has_split) {
  dedup_key <- paste(all_assessors_df$firstName, all_assessors_df$lastName)
} else {
  dedup_key <- all_assessors_df$assessorName
}

all_assessors_df$dedup_key <- dedup_key
unique_assessors <- all_assessors_df[!duplicated(dedup_key), ]

for (i in seq_len(nrow(unique_assessors))) {
  row <- unique_assessors[i, ]
  if (has_split) {
    dbExecute(con_out,
      "INSERT INTO assessors (firstName, lastName, email) VALUES (?, ?, ?)",
      params = list(row$firstName, row$lastName, row$email))
  } else {
    dbExecute(con_out,
      "INSERT INTO assessors (assessorName, email) VALUES (?, ?)",
      params = list(row$assessorName, row$email))
  }
  new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() AS id")$id
  unique_assessors$new_idAssessor[i] <- new_id
}

# Build full mapping (all source rows -> new ID via dedup key)
assessor_id_map <- all_assessors_df %>%
  left_join(unique_assessors %>% select(dedup_key, new_idAssessor), by = "dedup_key") %>%
  select(source_db, old_idAssessor = idAssessor, new_idAssessor)

n_dedup <- nrow(all_assessors_df) - nrow(unique_assessors)
cat(sprintf("  Assessors: %d merged (%d deduplicated)\n\n", nrow(unique_assessors), n_dedup))

# =============================================================================
# MERGE PESTS (deduplicate by eppoCode; blank EPPO inserted without dedup)
# =============================================================================
cat("=== Merging Pests ===\n")

all_pests <- list()
for (i in seq_len(nrow(source_files))) {
  tryCatch({
    con <- dbConnect(SQLite(), source_files$path[i])
    on.exit(dbDisconnect(con), add = TRUE)
    rows <- dbReadTable(con, "pests")
    dbDisconnect(con); on.exit()
    if (nrow(rows) == 0) next
    rows$source_db <- source_files$source_db[i]
    all_pests[[i]] <- rows
  }, error = function(e) warn_skip(paste("Cannot read pests from", source_files$source_db[i], ":", e$message)))
}

all_pests_df <- bind_rows(all_pests)

# Separate pests with valid EPPO code from those without
has_eppo  <- !is.na(all_pests_df$eppoCode) & trimws(all_pests_df$eppoCode) != ""
with_eppo <- all_pests_df[has_eppo, ]
no_eppo   <- all_pests_df[!has_eppo, ]

# Deduplicate: keep first occurrence per EPPO code
deduped_pests <- with_eppo[!duplicated(trimws(with_eppo$eppoCode)), ]

# All rows to insert = deduped + non-deduplicatable
pests_to_insert <- bind_rows(deduped_pests, no_eppo)

for (i in seq_len(nrow(pests_to_insert))) {
  p <- pests_to_insert[i, ]
  dbExecute(con_out,
    "INSERT INTO pests (scientificName, eppoCode, synonyms, vernacularName,
                        idTaxa, idQuarantineStatus, inEurope, gbifTaxonKey)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(p$scientificName, p$eppoCode, p$synonyms, p$vernacularName,
                  p$idTaxa, p$idQuarantineStatus, p$inEurope, p$gbifTaxonKey))
  new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() AS id")$id
  pests_to_insert$new_idPest[i] <- new_id
}

# Build full mapping: every source pest row -> new_idPest
eppo_to_new <- pests_to_insert %>%
  filter(!is.na(eppoCode) & trimws(eppoCode) != "") %>%
  select(eppoCode, new_idPest)

pest_id_map <- all_pests_df %>%
  mutate(eppo_trimmed = trimws(eppoCode)) %>%
  left_join(eppo_to_new, by = c("eppo_trimmed" = "eppoCode")) %>%
  mutate(new_idPest = coalesce(new_idPest,
    pests_to_insert$new_idPest[match(paste(source_db, idPest),
                                     paste(pests_to_insert$source_db, pests_to_insert$idPest))])) %>%
  select(source_db, old_idPest = idPest, new_idPest)

n_dedup_pests <- nrow(with_eppo) - nrow(deduped_pests)
if (nrow(no_eppo) > 0)
  cat(sprintf("  [WARN] %d pest(s) have blank EPPO code - inserted without deduplication\n", nrow(no_eppo)))
cat(sprintf("  Pests: %d merged (%d deduplicated by EPPO code)\n\n",
            nrow(pests_to_insert), n_dedup_pests))

# =============================================================================
# MERGE ASSESSMENTS
# =============================================================================
cat("=== Merging Assessments ===\n")

assessment_id_map <- data.frame(
  source_db        = character(),
  old_idAssessment = integer(),
  new_idAssessment = integer(),
  stringsAsFactors = FALSE
)
n_skipped_ass <- 0L

for (i in seq_len(nrow(source_files))) {
  src <- source_files$source_db[i]
  tryCatch({
    con <- dbConnect(SQLite(), source_files$path[i])
    on.exit(dbDisconnect(con), add = TRUE)
    rows <- dbReadTable(con, "assessments")
    dbDisconnect(con); on.exit()
    if (nrow(rows) == 0) next

    for (j in seq_len(nrow(rows))) {
      ass <- rows[j, ]

      new_pest <- pest_id_map %>%
        filter(source_db == src, old_idPest == ass$idPest) %>%
        pull(new_idPest)
      new_assessor <- assessor_id_map %>%
        filter(source_db == src, old_idAssessor == ass$idAssessor) %>%
        pull(new_idAssessor)

      if (length(new_pest) == 0 || length(new_assessor) == 0) {
        warn_skip(paste("Assessment", ass$idAssessment, "from", src,
                        "- missing pest/assessor mapping, skipping"))
        n_skipped_ass <- n_skipped_ass + 1L
        next
      }

      dbExecute(con_out,
        "INSERT INTO assessments (idPest, idAssessor, startDate, endDate,
                                  finished, valid, notes, version, hosts,
                                  potentialEntryPathways, reference)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params = list(new_pest[1], new_assessor[1],
                      ass$startDate, ass$endDate, ass$finished, ass$valid,
                      ass$notes, ass$version, ass$hosts,
                      ass$potentialEntryPathways, ass$reference))

      new_id <- dbGetQuery(con_out, "SELECT last_insert_rowid() AS id")$id
      assessment_id_map <- rbind(assessment_id_map, data.frame(
        source_db = src, old_idAssessment = ass$idAssessment,
        new_idAssessment = new_id, stringsAsFactors = FALSE))
    }
  }, error = function(e) warn_skip(paste("Cannot read assessments from", src, ":", e$message)))
}

cat(sprintf("  Assessments: %d merged (%d skipped)\n\n",
            nrow(assessment_id_map), n_skipped_ass))
