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
