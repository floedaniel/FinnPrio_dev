# clean_error_strings.R
# Finds every field containing the exact error string and replaces it with ""

library(DBI)
library(RSQLite)

# --- Configuration ---
dir()
db_path <- "./databases/daniel_database_2026/daniel_v008_2026-04-16T10-19-46_sdm.db"
error_string <- "ERROR: 'list' object has no attribute 'split'"

# --- Connect ---
con <- dbConnect(SQLite(), db_path)
on.exit(dbDisconnect(con), add = TRUE)

# --- Get all tables and their columns ---
tables <- dbListTables(con)

total_updated <- 0

for (tbl in tables) {
  # Get column info
  col_info <- dbGetQuery(con, sprintf("PRAGMA table_info('%s')", tbl))
  
  for (col in col_info$name) {
    # Count matches
    n <- dbGetQuery(con, sprintf(
      "SELECT COUNT(*) AS n FROM \"%s\" WHERE \"%s\" = ?",
      tbl, col
    ), params = list(error_string))$n
    
    if (n > 0) {
      cat(sprintf("  %s.%s: %d matches → replacing with ''\n", tbl, col, n))
      
      dbExecute(con, sprintf(
        "UPDATE \"%s\" SET \"%s\" = '' WHERE \"%s\" = ?",
        tbl, col, col
      ), params = list(error_string))
      
      total_updated <- total_updated + n
    }
  }
}

cat(sprintf("\nDone. Cleared %d fields in total.\n", total_updated))
