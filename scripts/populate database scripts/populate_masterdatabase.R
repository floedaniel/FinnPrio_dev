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
